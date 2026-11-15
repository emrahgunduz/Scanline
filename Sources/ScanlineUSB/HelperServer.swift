import Foundation

/// The helper's request loop: reads requests from `input`, drives the transport `open` returns,
/// and writes replies to `output`. One client, one scanner. Runs until the pipe closes, a `close`
/// request arrives, or a request can't be handled safely; the transport is always closed on exit.
public final class HelperServer {
    public enum Exit: Equatable, Sendable {
        /// Client closed the pipe or sent `close`.
        case closed
        /// Unknown op: replied with an error, then stopped (its body length is unknown).
        case unknownOp(UInt8)
        /// A request asked for more data than the helper allows.
        case outOfRange
        /// The client went away mid-request or while a reply was being written.
        case brokenPipe
    }

    private let input: Int32
    private let output: Int32
    private let log: (String) -> Void
    private let open: () throws -> ScannerTransport
    private var transport: ScannerTransport?

    public init(input: Int32, output: Int32, log: @escaping (String) -> Void = { _ in },
                open: @escaping () throws -> ScannerTransport) {
        self.input = input
        self.output = output
        self.log = log
        self.open = open
    }

    public func run() -> Exit {
        defer {
            if let t = transport { t.close(); transport = nil; log("device released") }
        }
        while true {
            let opByte: [UInt8]
            do {
                guard let b = try HelperIO.readExact(input, 1) else { return .closed }
                opByte = b
            } catch { return .brokenPipe }

            guard let op = ScanlineHelper.Op(rawValue: opByte[0]) else {
                _ = reply(ok: false, Array("unsupported op \(opByte[0])".utf8))
                return .unknownOp(opByte[0])
            }

            switch op {
            case .hello:
                guard reply(ok: true, HelperIO.u32(Int(ScanlineHelper.protocolVersion))) else { return .brokenPipe }

            case .open:
                if transport == nil {
                    do { transport = try open(); log("device captured") }
                    catch {
                        guard reply(ok: false, Array("\(error)".utf8)) else { return .brokenPipe }
                        continue
                    }
                }
                guard reply(ok: true, []) else { return .brokenPipe }

            case .execute:
                guard let head = try? HelperIO.readExact(input, 24) else { return .brokenPipe }
                let cdb = Array(head[0..<16])
                let dataIn = HelperIO.u32(head, 16), outLen = HelperIO.u32(head, 20)
                guard dataIn <= ScanlineHelper.maxDataIn, outLen <= ScanlineHelper.maxDataOut else {
                    _ = reply(ok: false, Array("request out of range".utf8))
                    return .outOfRange
                }
                guard let out = try? HelperIO.readExact(input, outLen) else { return .brokenPipe }
                guard let t = transport else {
                    guard reply(ok: false, Array("scanner not open".utf8)) else { return .brokenPipe }
                    continue
                }
                let ok: Bool
                do { ok = reply(ok: true, try t.execute(cdb: cdb, dataIn: dataIn, dataOut: out)) }
                catch { ok = reply(ok: false, Array("\(error)".utf8)) }
                guard ok else { return .brokenPipe }

            case .close:
                _ = reply(ok: true, [])
                return .closed
            }
        }
    }

    /// Writes one reply; false if the client is gone.
    private func reply(ok: Bool, _ payload: [UInt8]) -> Bool {
        (try? HelperIO.writeAll(output, HelperIO.response(ok: ok, payload))) != nil
    }
}
