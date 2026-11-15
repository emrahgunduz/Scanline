import Foundation

/// The privileged helper (`ScanlineHelper`). Capturing the scanner from macOS's mass-storage
/// driver needs root *inside the logged-in user's session* (a LaunchDaemon is refused when it
/// opens the USB interface). So the app starts the helper as its own child through one narrow
/// sudo rule, and talks to it over stdin/stdout. When the app quits or crashes the pipe closes,
/// the helper releases the scanner and exits.
///
/// Wire format (little-endian):
///   request:  op u8 (1 open, 2 execute, 3 close, 4 hello)
///             execute: cdb[16] · dataIn u32 · outLen u32 · out bytes
///   response: status u8 (0 ok, 1 error) · len u32 · payload (data, or UTF-8 error text)
///   hello:    reply payload is the helper's protocol version (u32). Protocol 2 helpers don't
///             know op 4: they close the pipe without replying.
public enum ScanlineHelper {
    /// Wire protocol spoken by this build. 3 added `hello`; open/execute/close are unchanged since 2.
    public static let protocolVersion: UInt32 = 3
    /// Oldest helper protocol this app can still drive.
    public static let minimumProtocol: UInt32 = 2

    public static let installedBinary = "/Library/PrivilegedHelperTools/local.scanline.helper"
    /// No "." in the name: sudo skips files in sudoers.d whose names contain one.
    public static let sudoersFile = "/etc/sudoers.d/scanline-helper"
    public static let legacySudoersFile = "/etc/sudoers.d/local.scanline.helper"
    public static let argument = "--stdio"
    /// Left over from helper version 1 (LaunchDaemon); removed on install.
    public static let legacyPlist = "/Library/LaunchDaemons/local.scanline.helper.plist"
    public static let legacyLabel = "local.scanline.helper"

    /// Largest image read the helper accepts (a page is ~16 MB raw).
    public static let maxDataIn = 16 << 20
    /// Largest host->device payload the helper accepts.
    public static let maxDataOut = 1 << 20
    /// Largest reply the app accepts (data plus a little slack for error text).
    public static let maxResponse = maxDataIn + 4096

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedBinary) && FileManager.default.fileExists(atPath: sudoersFile)
    }

    /// The sudoers rule: this user may run exactly the helper with its one argument, as root.
    public static func sudoersRule(user: String) -> String {
        "\(user) ALL=(root) NOPASSWD: \(installedBinary) \(argument)\n"
    }

    public enum Op: UInt8 { case open = 1, execute = 2, close = 3, hello = 4 }
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
        if count == 0 { return [] }
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
