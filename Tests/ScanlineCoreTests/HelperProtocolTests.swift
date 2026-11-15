import Foundation
import Testing
@testable import ScanlineCore

// The helper's wire protocol, end to end over real pipes: HelperTransport (app side) talking to
// HelperServer (helper side), with the simulated scanner or a recording fake behind it.

// MARK: Support

/// A transport that records what it was asked and can be told to fail.
final class RecordingTransport: ScannerTransport, @unchecked Sendable {
    let lock = NSLock()
    var executed: [[UInt8]] = []
    var closedCount = 0
    var reply: [UInt8] = [1, 2, 3]
    var failWith: Error?
    func execute(cdb: [UInt8], dataIn: Int, dataOut: [UInt8]) throws -> [UInt8] {
        try lock.withLock {
            executed.append(cdb)
            if let failWith { throw failWith }
            return dataIn > 0 ? Array(reply.prefix(dataIn)) : []
        }
    }
    func close() { lock.withLock { closedCount += 1 } }
}

/// Runs `serve` on its own thread with the far ends of two pipes; returns the app-side channel.
/// The server's output is closed when it returns, so the client sees EOF like a real exit.
func startServer(_ serve: @escaping @Sendable (_ input: Int32, _ output: Int32) -> Void) -> HelperTransport.Channel {
    signal(SIGPIPE, SIG_IGN)
    let requests = Pipe(), replies = Pipe()
    let input = requests.fileHandleForReading, output = replies.fileHandleForWriting
    Thread {
        serve(input.fileDescriptor, output.fileDescriptor)
        try? output.close()
        try? input.close()
    }.start()
    return HelperTransport.Channel(process: nil, toHelper: requests.fileHandleForWriting,
                                   fromHelper: replies.fileHandleForReading, stderr: nil)
}

/// A real HelperServer behind the channel; `exits` collects its exit reasons.
func serverChannel(_ make: @escaping @Sendable () throws -> ScannerTransport,
                   exits: Locked<[HelperServer.Exit]>? = nil) -> HelperTransport.Channel {
    startServer { i, o in
        let e = HelperServer(input: i, output: o, open: make).run()
        exits?.withLock { $0.append(e) }
    }
}

/// Raw request/response against a channel, for checking server replies byte by byte.
func roundTrip(_ ch: HelperTransport.Channel, _ request: [UInt8]) throws -> (ok: Bool, payload: [UInt8])? {
    try HelperIO.writeAll(ch.toHelper.fileDescriptor, request)
    guard let head = try HelperIO.readExact(ch.fromHelper.fileDescriptor, 5) else { return nil }
    let payload = try HelperIO.readExact(ch.fromHelper.fileDescriptor, HelperIO.u32(head, 1)) ?? []
    return (head[0] == 0, payload)
}

func waitFor(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.01) }
    return condition()
}

// MARK: End to end

@Test func helperRunsAWholeScanOverThePipe() throws {
    let sim = SimulatedScanner()
    sim.paper = true
    sim.nextPage = GrayImage(width: 2592, height: 600, fill: 180)
    let t = try HelperTransport { serverChannel({ sim }) }
    #expect(t.negotiatedProtocol == ScanlineHelper.protocolVersion)
    let s = IRIScanExpress4(transport: t)
    #expect(try s.identify() == "NOVA")
    let page = try s.scanPage()
    #expect(page.width == 2592 && page.height == 600)
    #expect(page.pixels.allSatisfy { $0 == 180 })
    t.close()
}

@Test func helperClosesTheScannerWhenTheAppGoesAway() throws {
    let fake = RecordingTransport()
    let exits = Locked<[HelperServer.Exit]>([])
    let t = try HelperTransport { serverChannel({ fake }, exits: exits) }
    _ = try t.execute(cdb: [0x12], dataIn: 2, dataOut: [])
    t.close()
    #expect(waitFor { exits.withLock { $0 } == [.closed] })
    #expect(fake.lock.withLock { fake.closedCount } == 1)
}

@Test func helperReleasesTheScannerOnPipeEOF() throws {
    let fake = RecordingTransport()
    let exits = Locked<[HelperServer.Exit]>([])
    let ch = serverChannel({ fake }, exits: exits)
    #expect(try roundTrip(ch, [ScanlineHelper.Op.open.rawValue])?.ok == true)
    try ch.toHelper.close()                       // app crashed: no close request
    #expect(waitFor { exits.withLock { $0 } == [.closed] })
    #expect(fake.lock.withLock { fake.closedCount } == 1)
}

// MARK: Handshake

@Test func helloReportsTheProtocolVersion() throws {
    let ch = serverChannel({ RecordingTransport() })
    let r = try #require(try roundTrip(ch, [ScanlineHelper.Op.hello.rawValue]))
    #expect(r.ok)
    #expect(UInt32(HelperIO.u32(r.payload)) == ScanlineHelper.protocolVersion)
}

/// A protocol-2 helper: no `hello` (it stops on the unknown op without replying), otherwise the same.
func legacyServer(_ fake: RecordingTransport, launches: Locked<Int>) -> HelperTransport.Channel {
    launches.withLock { $0 += 1 }
    return startServer { i, o in
        var opened = false
        while let op = try? HelperIO.readExact(i, 1) {
            switch op[0] {
            case 1: opened = true; try? HelperIO.writeAll(o, HelperIO.response(ok: true, []))
            case 2:
                guard let head = try? HelperIO.readExact(i, 24), let out = try? HelperIO.readExact(i, HelperIO.u32(head, 20)) else { return }
                let data = (try? fake.execute(cdb: Array(head[0..<16]), dataIn: HelperIO.u32(head, 16), dataOut: out)) ?? []
                try? HelperIO.writeAll(o, HelperIO.response(ok: opened, data))
            case 3: try? HelperIO.writeAll(o, HelperIO.response(ok: true, [])); return
            default: return                                   // v2: unknown op -> exit, no reply
            }
        }
    }
}

@Test func aLegacyHelperIsRelaunchedAndUsedAsProtocol2() throws {
    let fake = RecordingTransport()
    let launches = Locked(0)
    let t = try HelperTransport { legacyServer(fake, launches: launches) }
    #expect(t.negotiatedProtocol == 2)
    #expect(launches.withLock { $0 } == 2)                   // once for hello, once for real
    #expect(try t.execute(cdb: [0x12], dataIn: 3, dataOut: []) == [1, 2, 3])
    t.close()
}

@Test func aTooOldHelperIsReportedAsOutdated() throws {
    // A helper that answers hello with protocol 1.
    let launcher: HelperTransport.Launcher = {
        startServer { i, o in
            _ = try? HelperIO.readExact(i, 1)
            try? HelperIO.writeAll(o, HelperIO.response(ok: true, HelperIO.u32(1)))
            _ = try? HelperIO.readExact(i, 1)
        }
    }
    #expect {
        _ = try HelperTransport(launcher: launcher)
    } throws: { error in
        if case ScanError.helperOutdated(installed: 1) = error { return true }
        return false
    }
}

// MARK: Server edge cases

@Test(arguments: [UInt8(0x00), 0x05, 0xFF])
func unknownOpsGetAnErrorReplyThenTheServerStops(op: UInt8) throws {
    let exits = Locked<[HelperServer.Exit]>([])
    let ch = serverChannel({ RecordingTransport() }, exits: exits)
    let r = try #require(try roundTrip(ch, [op]))
    #expect(!r.ok)
    #expect(String(decoding: r.payload, as: UTF8.self) == "unsupported op \(op)")
    #expect(waitFor { exits.withLock { $0 } == [.unknownOp(op)] })
}

@Test func executeBeforeOpenIsRefusedAndTheServerCarriesOn() throws {
    let ch = serverChannel({ RecordingTransport() })
    let body = [UInt8](repeating: 0, count: 16) + HelperIO.u32(2) + HelperIO.u32(0)
    let r = try #require(try roundTrip(ch, [ScanlineHelper.Op.execute.rawValue] + body))
    #expect(!r.ok)
    #expect(String(decoding: r.payload, as: UTF8.self) == "scanner not open")
    #expect(try roundTrip(ch, [ScanlineHelper.Op.hello.rawValue])?.ok == true)   // still serving
}

@Test func oversizedRequestsStopTheServer() throws {
    let exits = Locked<[HelperServer.Exit]>([])
    let ch = serverChannel({ RecordingTransport() }, exits: exits)
    _ = try roundTrip(ch, [ScanlineHelper.Op.open.rawValue])
    let body = [UInt8](repeating: 0, count: 16) + HelperIO.u32(ScanlineHelper.maxDataIn + 1) + HelperIO.u32(0)
    let r = try #require(try roundTrip(ch, [ScanlineHelper.Op.execute.rawValue] + body))
    #expect(!r.ok)
    #expect(waitFor { exits.withLock { $0 } == [.outOfRange] })
}

@Test func anOpenFailureIsReportedAndCanBeRetried() throws {
    let attempts = Locked(0)
    let ch = serverChannel({
        let n = attempts.withLock { $0 += 1; return $0 }
        if n == 1 { throw ScanError.deviceNotFound }
        return RecordingTransport()
    })
    let first = try #require(try roundTrip(ch, [ScanlineHelper.Op.open.rawValue]))
    #expect(!first.ok)
    #expect(String(decoding: first.payload, as: UTF8.self).contains("scanner not found"))
    #expect(try roundTrip(ch, [ScanlineHelper.Op.open.rawValue])?.ok == true)
}

@Test func transportErrorsComeBackAsErrorReplies() throws {
    let fake = RecordingTransport()
    fake.failWith = ScanError.timeout("no image")
    let t = try HelperTransport { serverChannel({ fake }) }
    #expect(throws: ScanError.self) { _ = try t.execute(cdb: [0x28], dataIn: 4, dataOut: []) }
    // The connection survives a device error.
    fake.lock.withLock { fake.failWith = nil }
    #expect(try t.execute(cdb: [0x12], dataIn: 1, dataOut: []) == [1])
    t.close()
}

// MARK: Client robustness

/// A helper that answers hello, open, then sends `bad` as the reply to the first execute.
func misbehavingHelper(_ bad: [UInt8]) -> HelperTransport.Launcher {
    {
        startServer { i, o in
            _ = try? HelperIO.readExact(i, 1)
            try? HelperIO.writeAll(o, HelperIO.response(ok: true, HelperIO.u32(Int(ScanlineHelper.protocolVersion))))
            _ = try? HelperIO.readExact(i, 1)
            try? HelperIO.writeAll(o, HelperIO.response(ok: true, []))
            guard let op = try? HelperIO.readExact(i, 1), op[0] == 2, let head = try? HelperIO.readExact(i, 24) else { return }
            _ = try? HelperIO.readExact(i, HelperIO.u32(head, 20))
            try? HelperIO.writeAll(o, bad)
        }
    }
}

@Test func aReplyCutShortIsAnErrorNotData() throws {
    // Header promises 10 bytes, 3 arrive, then the helper exits.
    let t = try HelperTransport(launcher: misbehavingHelper([0] + HelperIO.u32(10) + [1, 2, 3]))
    #expect(throws: ScanError.self) { _ = try t.execute(cdb: [0x12], dataIn: 10, dataOut: []) }
}

@Test func anEmptyReplyAfterAHeaderOfDataIsAnError() throws {
    // Header promises 10 bytes, then EOF before any arrive (used to come back as empty success).
    let t = try HelperTransport(launcher: misbehavingHelper([0] + HelperIO.u32(10)))
    #expect(throws: ScanError.self) { _ = try t.execute(cdb: [0x12], dataIn: 10, dataOut: []) }
}

@Test func anOversizedReplyIsRejected() throws {
    // The header alone must be refused: the client never tries to allocate or read the payload.
    let t = try HelperTransport(launcher: misbehavingHelper([0] + HelperIO.u32(ScanlineHelper.maxResponse + 1)))
    #expect {
        _ = try t.execute(cdb: [0x12], dataIn: 10, dataOut: [])
    } throws: { error in
        if case ScanError.protocolError(let text) = error { return text.contains("too large") }
        return false
    }
}

@Test func aHelperThatDiesImmediatelyFailsCleanly() throws {
    // Launch "succeeds" but the helper dies without answering: hello sees EOF (or a failed
    // write, if it is already gone), the relaunch does too, and the error comes back.
    let launches = Locked(0)
    #expect(throws: ScanError.self) {
        _ = try HelperTransport { launches.withLock { $0 += 1 }; return startServer { _, _ in } }
    }
    #expect(launches.withLock { $0 } == 2)
}

@Test func aHelperThatReadsThenDiesFailsCleanly() throws {
    // Deterministic variant: the helper reads the request first, then exits without a reply.
    let launches = Locked(0)
    #expect(throws: ScanError.self) {
        _ = try HelperTransport { launches.withLock { $0 += 1 }; return startServer { i, _ in _ = try? HelperIO.readExact(i, 1) } }
    }
    #expect(launches.withLock { $0 } == 2)
}

@Test func aFailedOpenFromALiveHelperReturnsPromptly() throws {
    // An error reply means the helper is alive: no waiting for it to exit (the reconnect loop
    // retries every 2 s while no scanner is plugged in).
    let start = Date()
    #expect(throws: ScanError.self) {
        _ = try HelperTransport { serverChannel({ throw ScanError.deviceNotFound }) }
    }
    #expect(Date().timeIntervalSince(start) < 0.5)
}
