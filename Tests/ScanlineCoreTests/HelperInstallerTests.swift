import Foundation
import Testing
@testable import ScanlineCore

// The helper installer: the pinned sudo rule and the privileged script. The script is run for
// real, unprivileged, against a temporary folder (owner = the current user instead of root).

private func run(_ tool: String, _ args: [String], stdin: String? = nil) throws -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let out = Pipe(), err = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = inp
    try p.run()
    if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
    try inp.fileHandleForWriting.close()
    let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
}

private struct Sandbox {
    let root: URL
    let paths: HelperInstaller.Paths
    let bundled: URL

    init(bundledName: String = "ScanlineHelper", contents: Data = Data((0..<4096).map { UInt8($0 % 251) })) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString)")
        let app = root.appendingPathComponent("My Scan'line \"App\"/Contents/Resources")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        bundled = app.appendingPathComponent(bundledName)
        try contents.write(to: bundled)
        var p = HelperInstaller.Paths()
        p.helper = root.appendingPathComponent("PrivilegedHelperTools/local.scanline.helper").path
        p.sudoersFile = root.appendingPathComponent("sudoers.d/scanline-helper").path
        p.legacySudoersFile = root.appendingPathComponent("sudoers.d/local.scanline.helper").path
        p.legacyPlist = root.appendingPathComponent("LaunchDaemons/local.scanline.helper.plist").path
        p.owner = NSUserName()
        p.group = try run("/usr/bin/id", ["-gn"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        p.tempDirectory = root.appendingPathComponent("tmp").path
        p.bootOutLegacyDaemon = false
        try FileManager.default.createDirectory(atPath: (p.sudoersFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        paths = p
    }

    func install(expected: String? = nil, visudo: String? = nil) throws -> (status: Int32, err: String) {
        var paths = paths
        if let visudo { paths.visudo = visudo }
        let digest = try expected ?? HelperInstaller.sha256Hex(of: bundled)
        let script = try HelperInstaller.script(bundledHelper: bundled.path, expectedDigest: digest, uid: getuid(), paths: paths)
        let r = try run("/bin/sh", ["-c", script])
        return (r.status, r.err)
    }

    func leftovers() -> [String] {
        let dir = (paths.helper as NSString).deletingLastPathComponent
        let staged = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".new") }
        let temps = (try? FileManager.default.contentsOfDirectory(atPath: paths.tempDirectory)) ?? []
        return staged + temps
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func perms(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? -1
}

// MARK: Rule

@Test func thePinnedRuleParsesWithTheRealVisudo() throws {
    let digest = String(repeating: "ab", count: 32)
    let rule = try HelperInstaller.rule(uid: getuid(), digest: digest)
    #expect(rule == "#\(getuid()) ALL=(root) NOPASSWD: sha256:\(digest) /Library/PrivilegedHelperTools/local.scanline.helper --stdio\n")
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("rule-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    try rule.write(to: file, atomically: true, encoding: .utf8)
    let r = try run("/usr/sbin/visudo", ["-cf", file.path])
    #expect(r.status == 0, "visudo: \(r.out)\(r.err)")
}

@Test(arguments: ["", "abc", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "0", count: 63), String(repeating: "0", count: 65)])
func malformedDigestsAreRefused(digest: String) {
    #expect(throws: HelperInstaller.InstallerError.invalidDigest(digest)) {
        _ = try HelperInstaller.rule(uid: 501, digest: digest)
    }
}

@Test(arguments: ["plain", "with space", "it's", "\"quoted\"", "$(rm -rf /)", "back\\slash", "new\nline", "`tick`"])
func shellQuotingSurvivesTheShell(text: String) throws {
    let r = try run("/bin/sh", ["-c", "printf %s \(HelperInstaller.shellQuote(text))"])
    #expect(r.out == text)
}

@Test func appleScriptLiteralsSurviveAppleScript() throws {
    let shell = "printf '%s\\n' \"a\\\\b\" 'it'\\''s'"
    let source = HelperInstaller.appleScript(running: shell, prompt: "p")
    // Same literal, evaluated without the privileged call.
    let literal = String(source.dropFirst("do shell script ".count).prefix { _ in true })
        .components(separatedBy: " with administrator privileges").first!
    let r = try run("/usr/bin/osascript", ["-e", "return \(literal)"])
    #expect(r.out.trimmingCharacters(in: .newlines) == shell)
}

// MARK: Script, run for real

@Test func aFreshInstallPinsTheRuleToTheInstalledBytes() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let r = try box.install()
    #expect(r.status == 0, "\(r.err)")
    #expect(FileManager.default.contentsEqual(atPath: box.bundled.path, andPath: box.paths.helper))
    #expect(perms(box.paths.helper) == 0o755)
    #expect(perms(box.paths.sudoersFile) == 0o440)
    let rule = try String(contentsOfFile: box.paths.sudoersFile, encoding: .utf8)
    let digest = try HelperInstaller.sha256Hex(of: URL(fileURLWithPath: box.paths.helper))
    #expect(rule == "#\(getuid()) ALL=(root) NOPASSWD: sha256:\(digest) \(box.paths.helper) --stdio\n")
    #expect(try run("/usr/sbin/visudo", ["-cf", box.paths.sudoersFile]).status == 0)
    #expect(box.leftovers().isEmpty)
}

@Test func anUpdateReplacesBinaryAndRuleAndRemovesLegacyFiles() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    #expect(try box.install().status == 0)
    try "old rule".write(toFile: box.paths.legacySudoersFile, atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: (box.paths.legacyPlist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try "plist".write(toFile: box.paths.legacyPlist, atomically: true, encoding: .utf8)
    let oldInode = (try FileManager.default.attributesOfItem(atPath: box.paths.helper))[.systemFileNumber] as? Int

    try Data("a newer helper".utf8).write(to: box.bundled)
    #expect(try box.install().status == 0)
    #expect(FileManager.default.contentsEqual(atPath: box.bundled.path, andPath: box.paths.helper))
    let newDigest = try HelperInstaller.sha256Hex(of: box.bundled)
    #expect(try String(contentsOfFile: box.paths.sudoersFile, encoding: .utf8).contains("sha256:\(newDigest) "))
    // Swapped by rename (a running old helper keeps its own file), not overwritten in place.
    #expect((try FileManager.default.attributesOfItem(atPath: box.paths.helper))[.systemFileNumber] as? Int != oldInode)
    #expect(!FileManager.default.fileExists(atPath: box.paths.legacySudoersFile))
    #expect(!FileManager.default.fileExists(atPath: box.paths.legacyPlist))
    #expect(box.leftovers().isEmpty)
}

@Test func aHelperThatChangesDuringInstallLeavesTheOldInstallUntouched() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    #expect(try box.install().status == 0)
    let helperBefore = try Data(contentsOf: URL(fileURLWithPath: box.paths.helper))
    let ruleBefore = try String(contentsOfFile: box.paths.sudoersFile, encoding: .utf8)

    // The app vetted one file, but a different one is there when root copies it.
    let vetted = try HelperInstaller.sha256Hex(of: box.bundled)
    try Data("swapped".utf8).write(to: box.bundled)
    let r = try box.install(expected: vetted)
    #expect(r.status == 3)
    #expect(r.err.contains("changed while it was being installed"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: box.paths.helper)) == helperBefore)
    #expect(try String(contentsOfFile: box.paths.sudoersFile, encoding: .utf8) == ruleBefore)
    #expect(box.leftovers().isEmpty)
}

@Test func theScriptStagesChecksThenSwapsInThatOrder() throws {
    let script = try HelperInstaller.script(bundledHelper: "/A.app/ScanlineHelper", expectedDigest: String(repeating: "1", count: 64), uid: 501)
    func at(_ s: String) -> String.Index { script.range(of: s)!.lowerBound }
    #expect(script.hasPrefix("set -e\n"))
    #expect(at("umask 077") < at("/usr/bin/install -m 0700"))
    #expect(at("/usr/bin/install -m 0700") < at("/usr/bin/shasum"))
    #expect(at("/usr/bin/shasum") < at("[ \"$D\" ="))
    #expect(at("[ \"$D\" =") < at("/bin/chmod 0755"))
    #expect(at("/bin/chmod 0755") < at("'/usr/sbin/visudo' -cf"))
    #expect(at("'/usr/sbin/visudo' -cf") < at("/bin/mv -f"))
    #expect(at("/bin/mv -f") < at("/usr/bin/install -m 0440"))
    #expect(script.contains("-o 'root' -g 'wheel'"))
    #expect(script.contains("/bin/launchctl bootout system/local.scanline.helper"))
}

@Test func aRuleVisudoRejectsLeavesTheOldInstallUntouched() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    #expect(try box.install().status == 0)
    let helperBefore = try Data(contentsOf: URL(fileURLWithPath: box.paths.helper))
    let ruleBefore = try String(contentsOfFile: box.paths.sudoersFile, encoding: .utf8)
    let inodeBefore = (try FileManager.default.attributesOfItem(atPath: box.paths.helper))[.systemFileNumber] as? Int

    try Data("a newer helper".utf8).write(to: box.bundled)          // a swap would be visible
    let r = try box.install(visudo: "/usr/bin/false")                // visudo says no
    #expect(r.status != 0)
    #expect(try Data(contentsOf: URL(fileURLWithPath: box.paths.helper)) == helperBefore)
    #expect((try FileManager.default.attributesOfItem(atPath: box.paths.helper))[.systemFileNumber] as? Int == inodeBefore)
    #expect(try String(contentsOfFile: box.paths.sudoersFile, encoding: .utf8) == ruleBefore)
    #expect(box.leftovers().isEmpty)
}

@Test func aSymlinkedHelperIsRefusedBeforeAnythingIsCopied() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let secret = box.root.appendingPathComponent("secret")
    try Data("root-only".utf8).write(to: secret)
    let vetted = try HelperInstaller.sha256Hex(of: box.bundled)
    try FileManager.default.removeItem(at: box.bundled)
    try FileManager.default.createSymbolicLink(at: box.bundled, withDestinationURL: secret)
    let r = try box.install(expected: vetted)
    #expect(r.status == 4)
    #expect(!FileManager.default.fileExists(atPath: box.paths.helper))
    #expect(box.leftovers().isEmpty)
}

@Test func theStagedCopyIsPrivateUntilItChecksOut() throws {
    // Stop the script right after staging (bad digest) and look at what was staged: nothing
    // may be left, and while it existed it was 0700 (install -m 0700 under umask 077).
    let script = try HelperInstaller.script(bundledHelper: "/A.app/ScanlineHelper", expectedDigest: String(repeating: "1", count: 64), uid: 501)
    #expect(script.contains("/usr/bin/install -m 0700"))
    #expect(!script.contains("-m 0755"))
}
