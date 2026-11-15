import Foundation
import Security

/// Is the installed helper in step with the one this app ships? Read without root.
///
/// "Same helper" means the same *code hash* (CDHash): it covers the code and the signing
/// identity, but not the signature's timestamp, so re-signing identical code doesn't count as
/// a change. sudo's own pin (the file's SHA-256) still guards the exact installed bytes.
public enum HelperStatus: Equatable, Sendable {
    /// This build has no bundled helper (e.g. `swift run`): never nag, use what is installed.
    case bundleMissing
    case notInstalled
    /// Binary present, sudo rule missing.
    case ruleMissing
    /// Installed with the old rule that isn't pinned to the helper's bytes.
    case unpinned
    case current
    /// Installed helper differs from the bundled one (it may still work).
    case outdated

    /// Everything the classification needs, gathered from the file system and sudo.
    public struct Facts: Equatable, Sendable {
        public var bundledCodeHash: String?
        public var installedExists: Bool
        public var installedCodeHash: String?
        public var ruleExists: Bool
        /// Whether sudo's rule for the helper carries a digest; nil if it couldn't be read.
        public var rulePinned: Bool?
        public init(bundledCodeHash: String?, installedExists: Bool, installedCodeHash: String?,
                    ruleExists: Bool, rulePinned: Bool?) {
            self.bundledCodeHash = bundledCodeHash
            self.installedExists = installedExists
            self.installedCodeHash = installedCodeHash
            self.ruleExists = ruleExists
            self.rulePinned = rulePinned
        }
    }

    public static func classify(_ f: Facts) -> HelperStatus {
        guard let bundled = f.bundledCodeHash else { return .bundleMissing }
        guard f.installedExists else { return .notInstalled }
        guard f.ruleExists else { return .ruleMissing }
        if f.rulePinned == false { return .unpinned }
        return f.installedCodeHash == bundled ? .current : .outdated
    }

    /// Gathers the facts for the installed helper and `bundled` (the app's copy).
    public static func facts(bundled: URL?, installed: String = ScanlineHelper.installedBinary,
                             rule: String = ScanlineHelper.sudoersFile) -> Facts {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: installed)
        return Facts(bundledCodeHash: bundled.flatMap { codeHash(of: $0) },
                     installedExists: exists,
                     installedCodeHash: exists ? codeHash(of: URL(fileURLWithPath: installed)) : nil,
                     ruleExists: fm.fileExists(atPath: rule),
                     rulePinned: exists ? sudoRulePinned(for: installed) : nil)
    }

    /// The CDHash of a signed (or ad-hoc signed) binary, hex; nil if unsigned or unreadable.
    public static func codeHash(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let hash = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the user's sudo rules (`sudo -n -l`, no password needed with a NOPASSWD rule) and
    /// reports whether the helper's rule carries a digest. nil when sudo can't be asked.
    public static func sudoRulePinned(for helper: String) -> Bool? {
        guard let text = run("/usr/bin/sudo", ["-n", "-l"], timeout: 3) else { return nil }
        return pinned(inSudoList: text, helper: helper)
    }

    /// Parses `sudo -l` output: nil if no rule mentions the helper.
    public static func pinned(inSudoList text: String, helper: String) -> Bool? {
        let lines = text.split(separator: "\n").filter { $0.contains(helper) }
        guard !lines.isEmpty else { return nil }
        return lines.contains { $0.contains("sha256:") }
    }

    private static func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
