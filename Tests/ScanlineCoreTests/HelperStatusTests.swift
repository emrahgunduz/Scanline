import Foundation
import Testing
@testable import ScanlineCore

// Helper status: classification, sudo rule parsing, code hashes; and the session behaviour the
// update flow relies on (prompt stop, slow retry while the helper is out of date).

private func facts(bundled: String? = "aa", exists: Bool = true, installed: String? = "aa",
                   rule: Bool = true, pinned: Bool? = true) -> HelperStatus.Facts {
    HelperStatus.Facts(bundledCodeHash: bundled, installedExists: exists, installedCodeHash: installed,
                       ruleExists: rule, rulePinned: pinned)
}

@Test func classificationCoversEveryState() {
    #expect(HelperStatus.classify(facts()) == .current)
    #expect(HelperStatus.classify(facts(installed: "bb")) == .outdated)
    #expect(HelperStatus.classify(facts(installed: nil)) == .outdated)          // unreadable/unsigned
    #expect(HelperStatus.classify(facts(pinned: false)) == .unpinned)
    #expect(HelperStatus.classify(facts(pinned: nil)) == .current)              // sudo couldn't say: don't nag
    #expect(HelperStatus.classify(facts(rule: false)) == .ruleMissing)
    #expect(HelperStatus.classify(facts(exists: false, installed: nil, rule: false)) == .notInstalled)
    #expect(HelperStatus.classify(facts(bundled: nil)) == .bundleMissing)       // dev build: never nag
    #expect(HelperStatus.classify(facts(bundled: nil, exists: false)) == .bundleMissing)
}

@Test func sudoListParsing() {
    let helper = "/Library/PrivilegedHelperTools/local.scanline.helper"
    let pinned = """
    Matching Defaults entries for me on mac:
        env_reset, env_keep+=BLOCKSIZE

    User me may run the following commands on mac:
        (root) NOPASSWD: sha256:0123abcd \(helper) --stdio
    """
    let unpinned = pinned.replacingOccurrences(of: "sha256:0123abcd ", with: "")
    #expect(HelperStatus.pinned(inSudoList: pinned, helper: helper) == true)
    #expect(HelperStatus.pinned(inSudoList: unpinned, helper: helper) == false)
    #expect(HelperStatus.pinned(inSudoList: "User me may run: (ALL) ALL", helper: helper) == nil)
}

private func copyAndSign(_ tool: String, to dir: URL, name: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try FileManager.default.copyItem(atPath: tool, toPath: url.path)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    // Fixed identifier, as build-app.sh signs the helper (ad-hoc defaults to the file name).
    p.arguments = ["--force", "--sign", "-", "--identifier", "ScanlineHelper", url.path]
    p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    #expect(p.terminationStatus == 0)
    return url
}

@Test func codeHashIsStableAcrossResigningAndChangesWithTheCode() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cdhash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let a = try copyAndSign("/usr/bin/true", to: dir, name: "a")
    let first = try #require(HelperStatus.codeHash(of: a))
    // Re-sign the same code: same identity, same hash (the file's bytes may differ).
    let again = try copyAndSign(a.path, to: dir, name: "a2")
    #expect(HelperStatus.codeHash(of: again) == first)
    // Different code: different hash.
    let b = try copyAndSign("/bin/echo", to: dir, name: "a3")
    #expect(HelperStatus.codeHash(of: b) != first)
    // Not code at all: no hash.
    let junk = dir.appendingPathComponent("junk")
    try Data("not a binary".utf8).write(to: junk)
    #expect(HelperStatus.codeHash(of: junk) == nil)
    #expect(HelperStatus.codeHash(of: dir.appendingPathComponent("missing")) == nil)
}

// MARK: Session

private func session(_ make: @escaping @Sendable () throws -> ScannerTransport, attempts: Locked<Int>) -> ScanSession {
    var s = ScanSession.Settings()
    s.pollInterval = 0.05
    return ScanSession(settings: s, logURL: nil, transport: {
        attempts.withLock { $0 += 1 }
        return try make()
    }) { _ in }
}

@Test func stopAndWaitReturnsPromptlyWhileDisconnected() throws {
    let attempts = Locked(0)
    let s = session({ throw ScanError.deviceNotFound }, attempts: attempts)
    s.start()
    #expect(waitFor { attempts.withLock { $0 } >= 1 })
    let start = Date()
    #expect(s.stopAndWait(timeout: 3))                       // wakes out of the 2 s retry pause
    #expect(Date().timeIntervalSince(start) < 0.5)
}

@Test func stopAndWaitClosesTheTransport() throws {
    let fake = RecordingTransport()
    let sim = SimulatedScanner()
    let attempts = Locked(0)
    // A transport that is the simulator but records close().
    final class Closing: ScannerTransport, @unchecked Sendable {
        let inner: SimulatedScanner; let fake: RecordingTransport
        init(_ i: SimulatedScanner, _ f: RecordingTransport) { inner = i; fake = f }
        func execute(cdb: [UInt8], dataIn: Int, dataOut: [UInt8]) throws -> [UInt8] { try inner.execute(cdb: cdb, dataIn: dataIn, dataOut: dataOut) }
        func close() { fake.close() }
    }
    let s = session({ Closing(sim, fake) }, attempts: attempts)
    s.start()
    #expect(waitFor { attempts.withLock { $0 } >= 1 })
    Thread.sleep(forTimeInterval: 0.2)                        // connected and polling
    #expect(s.stopAndWait(timeout: 3))
    #expect(fake.lock.withLock { fake.closedCount } == 1)
    #expect(s.stopAndWait(timeout: 1))                        // idempotent
}

@Test func anOutdatedHelperIsRetriedSlowly() throws {
    let outdated = Locked(0), other = Locked(0)
    let a = session({ throw ScanError.helperOutdated(installed: 1) }, attempts: outdated)
    let b = session({ throw ScanError.deviceNotFound }, attempts: other)
    a.start(); b.start()
    Thread.sleep(forTimeInterval: 2.6)
    #expect(outdated.withLock { $0 } == 1)                    // waits 10 s before trying again
    #expect(other.withLock { $0 } == 2)                       // normal 2 s retry
    #expect(a.stopAndWait(timeout: 2))
    #expect(b.stopAndWait(timeout: 2))
}
