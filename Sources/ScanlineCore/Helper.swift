import Foundation

/// App side: the scanner through the helper child process (see `ScanlineHelper` for the wire).
///
/// On connect it says `hello` to learn the helper's protocol. A protocol-2 helper doesn't know
/// `hello` and simply exits, so the transport launches it again and carries on with protocol 2.
public final class HelperTransport: ScannerTransport, @unchecked Sendable {
    /// One running helper: the pipe ends the app uses and, when launched, its process.
    public struct Channel {
        public var process: Process?
        public var toHelper: FileHandle
        public var fromHelper: FileHandle
        public var stderr: FileHandle?
        public init(process: Process?, toHelper: FileHandle, fromHelper: FileHandle, stderr: FileHandle?) {
            self.process = process
            self.toHelper = toHelper
            self.fromHelper = fromHelper
            self.stderr = stderr
        }
    }
    public typealias Launcher = () throws -> Channel

    private let launch: Launcher
    private var channel: Channel
    private var closed = false
    /// Set when the last request got an error *reply*: the helper is alive, so sudo didn't refuse.
    private var lastReplyWasError = false
    /// Protocol the connected helper speaks (2 for helpers older than `hello`).
    public private(set) var negotiatedProtocol: UInt32 = 0

    /// The installed helper, started through its sudo rule.
    public convenience init() throws {
        try self.init(launcher: HelperTransport.sudoLauncher)
    }

    /// Any helper the launcher starts (tests use in-process servers on pipes).
    public init(launcher: @escaping Launcher) throws {
        // A helper that dies must never take the app down with it.
        signal(SIGPIPE, SIG_IGN)
        launch = launcher
        channel = try launcher()
        do {
            negotiatedProtocol = try handshake()
            guard negotiatedProtocol >= ScanlineHelper.minimumProtocol else {
                throw ScanError.helperOutdated(installed: negotiatedProtocol)
            }
            _ = try request(.open, [])
        } catch {
            // Close our end first: a live helper then sees EOF and exits at once, so the
            // check for a sudo refusal below never waits on a helper that is still running.
            shutDownChannel()
            closed = true
            throw lastReplyWasError ? error : (authorisationFailure() ?? error)
        }
    }

    deinit { close() }

    public static func sudoLauncher() throws -> Channel {
        let p = Process()
        let toHelper = Pipe(), fromHelper = Pipe(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", ScanlineHelper.installedBinary, ScanlineHelper.argument]
        p.standardInput = toHelper
        p.standardOutput = fromHelper
        p.standardError = errors
        try p.run()
        return Channel(process: p, toHelper: toHelper.fileHandleForWriting,
                       fromHelper: fromHelper.fileHandleForReading, stderr: errors.fileHandleForReading)
    }

    /// Learns the helper's protocol. A helper that closes the pipe instead of answering is
    /// protocol 2, unless sudo refused to start it at all.
    private func handshake() throws -> UInt32 {
        do {
            let reply = try request(.hello, [])
            guard reply.count >= 4 else { throw ScanError.protocolError("helper sent a malformed hello") }
            return UInt32(HelperIO.u32(reply))
        } catch let error as ScanError {
            // The helper went away instead of answering: EOF, or it was gone before we could write.
            guard case .protocolError(let text) = error,
                  text == Self.stoppedText || text.hasPrefix(HelperIO.writeFailedPrefix) else { throw error }
            if let refused = authorisationFailure() { throw refused }
            // Legacy helper: it exited on the unknown op. Start a fresh one and skip hello.
            shutDownChannel()
            channel = try launch()
            return 2
        }
    }

    private static let stoppedText = "the helper stopped"

    private func request(_ op: ScanlineHelper.Op, _ body: [UInt8]) throws -> [UInt8] {
        lastReplyWasError = false
        let out = channel.toHelper.fileDescriptor
        let inp = channel.fromHelper.fileDescriptor
        try HelperIO.writeAll(out, [op.rawValue] + body)
        guard let head = try HelperIO.readExact(inp, 5) else { throw ScanError.protocolError(Self.stoppedText) }
        let len = HelperIO.u32(head, 1)
        guard len <= ScanlineHelper.maxResponse else { throw ScanError.protocolError("helper reply too large (\(len) bytes)") }
        guard let payload = try HelperIO.readExact(inp, len) else {
            throw ScanError.protocolError("helper reply cut short")
        }
        if head[0] != 0 {
            lastReplyWasError = true
            throw ScanError.protocolError(String(decoding: payload, as: UTF8.self))
        }
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
        shutDownChannel()
    }

    // MARK: Failure handling

    /// If the launched sudo exited because the rule doesn't allow it, the error to show.
    private func authorisationFailure() -> Error? {
        guard let p = channel.process, let stderr = channel.stderr else { return nil }
        // stderr can only be drained safely once the child has exited; give it a moment.
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !p.isRunning else { return nil }
        let text = String(decoding: stderr.availableData, as: UTF8.self)
        if text.contains("password") || text.contains("not allowed") || text.contains("sudoers") {
            return ScanError.helperNotAuthorised
        }
        return nil
    }

    private func shutDownChannel() {
        try? channel.toHelper.close()
        if let p = channel.process, p.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        }
    }
}
