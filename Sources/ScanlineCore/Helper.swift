import Foundation

/// The privileged helper (`ScanlineHelper`). Capturing the scanner from macOS's mass-storage
/// driver needs root *inside the logged-in user's session* (a LaunchDaemon is refused when it
/// opens the USB interface). So the app starts the helper as its own child through one narrow
/// sudo rule, and talks to it over stdin/stdout. When the app quits or crashes the pipe closes,
/// the helper releases the scanner and exits.
///
/// Wire format (little-endian):
///   request:  op u8 (1 open, 2 execute, 3 close)
///             execute: cdb[16] · dataIn u32 · outLen u32 · out bytes
///   response: status u8 (0 ok, 1 error) · len u32 · payload (data, or UTF-8 error text)
public enum ScanlineHelper {
    public static let version = "2"
    public static let installedBinary = "/Library/PrivilegedHelperTools/local.scanline.helper"
    /// No "." in the name: sudo skips files in sudoers.d whose names contain one.
    public static let sudoersFile = "/etc/sudoers.d/scanline-helper"
    public static let legacySudoersFile = "/etc/sudoers.d/local.scanline.helper"
    public static let argument = "--stdio"
    /// Left over from helper version 1 (LaunchDaemon); removed on install.
    public static let legacyPlist = "/Library/LaunchDaemons/local.scanline.helper.plist"
    public static let legacyLabel = "local.scanline.helper"

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedBinary) && FileManager.default.fileExists(atPath: sudoersFile)
    }

    /// The sudoers rule: this user may run exactly the helper with its one argument, as root.
    public static func sudoersRule(user: String) -> String {
        "\(user) ALL=(root) NOPASSWD: \(installedBinary) \(argument)\n"
    }

    public enum Op: UInt8 { case open = 1, execute = 2, close = 3 }
}

// MARK: Framing

public enum HelperIO {
    public static func writeAll(_ fd: Int32, _ data: [UInt8]) throws {
        var off = 0
        while off < data.count {
            let n = data[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; throw ScanError.protocolError("helper pipe write failed (\(errno))") }
            off += n
        }
    }

    /// Reads exactly `count` bytes; nil on clean EOF before the first byte.
    public static func readExact(_ fd: Int32, _ count: Int) throws -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count)
        var off = 0
        while off < count {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + off, count - off) }
            if n == 0 { if off == 0 { return nil }; throw ScanError.protocolError("helper pipe closed mid-message") }
            if n < 0 { if errno == EINTR { continue }; throw ScanError.protocolError("helper pipe read failed (\(errno))") }
            off += n
        }
        return buf
    }

    public static func u32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).littleEndian) { Array($0) } }
    public static func u32(_ b: [UInt8], _ o: Int = 0) -> Int {
        Int(UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
    }

    public static func response(ok: Bool, _ payload: [UInt8]) -> [UInt8] { [ok ? 0 : 1] + u32(payload.count) + payload }
}

/// App side: the scanner through the helper child process.
public final class HelperTransport: ScannerTransport, @unchecked Sendable {
    private let process = Process()
    private let toHelper = Pipe()
    private let fromHelper = Pipe()
    private let errors = Pipe()
    private var closed = false

    public init() throws {
        // A helper that dies must never take the app down with it.
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", ScanlineHelper.installedBinary, ScanlineHelper.argument]
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.standardError = errors
        try process.run()
        do {
            _ = try request(.open, [])
        } catch {
            // stderr is only safe to drain once the child has exited (otherwise it may block).
            if process.isRunning == false {
                let stderr = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
                close()
                if stderr.contains("password") || stderr.contains("not allowed") {
                    throw ScanError.protocolError("the Scanline helper is not authorised; reinstall it in Settings")
                }
                throw error
            }
            close()
            throw error
        }
    }

    deinit { close() }

    private func request(_ op: ScanlineHelper.Op, _ body: [UInt8]) throws -> [UInt8] {
        let out = toHelper.fileHandleForWriting.fileDescriptor
        let inp = fromHelper.fileHandleForReading.fileDescriptor
        try HelperIO.writeAll(out, [op.rawValue] + body)
        guard let head = try HelperIO.readExact(inp, 5) else { throw ScanError.protocolError("the helper stopped") }
        let len = HelperIO.u32(head, 1)
        let payload = len > 0 ? (try HelperIO.readExact(inp, len) ?? []) : []
        if head[0] != 0 { throw ScanError.protocolError(String(decoding: payload, as: UTF8.self)) }
        return payload
    }

    public func execute(cdb: [UInt8], dataIn: Int, dataOut: [UInt8]) throws -> [UInt8] {
        var c = cdb + [UInt8](repeating: 0, count: max(0, 16 - cdb.count))
        c = Array(c.prefix(16))
        return try request(.execute, c + HelperIO.u32(dataIn) + HelperIO.u32(dataOut.count) + dataOut)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        _ = try? request(.close, [])
        try? toHelper.fileHandleForWriting.close()
        if process.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in if process.isRunning { process.terminate() } }
        }
    }
}
