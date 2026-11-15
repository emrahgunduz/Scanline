// ScanlineHelper: gives the Scanline app raw USB access to the IRIScan Express 4.
// Started by the app as `sudo -n local.scanline.helper --stdio` (root, in the user's session),
// it serves one client over stdin/stdout and exits when the pipe closes. No kext involved.
import Darwin
import Foundation
import ScanlineCore

func log(_ s: String) { FileHandle.standardError.write(Data("ScanlineHelper: \(s)\n".utf8)) }

guard CommandLine.arguments.dropFirst().first == ScanlineHelper.argument else {
    log("usage: \(CommandLine.arguments[0]) \(ScanlineHelper.argument)")
    exit(64)
}
signal(SIGPIPE, SIG_IGN)

let input = STDIN_FILENO, output = STDOUT_FILENO
nonisolated(unsafe) var transport: USBTransport?

func reply(ok: Bool, _ payload: [UInt8]) {
    do { try HelperIO.writeAll(output, HelperIO.response(ok: ok, payload)) } catch { transport?.close(); exit(1) }
}

func shutdown() -> Never {
    if let t = transport { t.close(); log("device released") }
    exit(0)
}

while true {
    guard let opByte = (try? HelperIO.readExact(input, 1)) ?? nil, let op = ScanlineHelper.Op(rawValue: opByte[0]) else {
        shutdown()   // pipe closed (app quit or crashed) or garbage
    }
    switch op {
    case .open:
        if transport == nil {
            do { transport = try USBTransport(); log("device captured") }
            catch { reply(ok: false, Array("\(error)".utf8)); continue }
        }
        reply(ok: true, [])
    case .execute:
        guard let head = (try? HelperIO.readExact(input, 24)) ?? nil else { shutdown() }
        let cdb = Array(head[0..<16])
        let dataIn = HelperIO.u32(head, 16), outLen = HelperIO.u32(head, 20)
        guard dataIn <= 16 << 20, outLen <= 1 << 20 else { reply(ok: false, Array("request out of range".utf8)); shutdown() }
        let out = outLen > 0 ? ((try? HelperIO.readExact(input, outLen)) ?? nil) : []
        guard let out else { shutdown() }
        guard let t = transport else { reply(ok: false, Array("scanner not open".utf8)); continue }
        do { reply(ok: true, try t.execute(cdb: cdb, dataIn: dataIn, dataOut: out)) }
        catch { reply(ok: false, Array("\(error)".utf8)) }
    case .close:
        reply(ok: true, [])
        shutdown()
    }
}
