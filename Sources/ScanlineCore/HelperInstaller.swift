import CryptoKit
import Foundation

/// Builds the one privileged script that installs (or updates) the helper and its sudo rule.
///
/// The rule pins the helper's exact bytes with a SHA-256 digest, so sudo will only run *that*
/// file as root. The order makes every failure safe:
///   1. stage the bundled helper next to the destination (`.new`, root-owned)
///   2. hash the staged copy as root, and require it to match what the app vetted
///      (the app bundle is writable by the user, so it could change between the two)
///   3. write the rule from root's hash to a root-only temp file and check it with `visudo -cf`
///   4. only then swap in the binary (atomic `mv`) and the rule, back to back
/// Anything failing before step 4 leaves the working install untouched.
public enum HelperInstaller {
    public struct Paths: Sendable {
        public var helper = ScanlineHelper.installedBinary
        public var sudoersFile = ScanlineHelper.sudoersFile
        public var legacySudoersFile = ScanlineHelper.legacySudoersFile
        public var legacyPlist = ScanlineHelper.legacyPlist
        public var legacyLabel = ScanlineHelper.legacyLabel
        public var owner = "root"
        public var group = "wheel"
        public var tempDirectory = "/private/tmp"
        /// Stop the old LaunchDaemon (helper v1). Off in tests.
        public var bootOutLegacyDaemon = true
        public init() {}
    }

    public enum InstallerError: Error, Equatable, CustomStringConvertible {
        case invalidUserName(String)
        case invalidDigest(String)
        public var description: String {
            switch self {
            case let .invalidUserName(u): "can't write a sudo rule for the user name “\(u)”"
            case let .invalidDigest(d): "not a SHA-256 digest: \(d)"
            }
        }
    }

    /// User names that can appear unquoted in a sudoers rule.
    public static func isValidUserName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first != "-", name.count <= 255 else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
    }

    public static func isValidDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }

    public static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The sudo rule: `user` may run exactly this helper file (by digest) with its one argument.
    public static func rule(user: String, digest: String, paths: Paths = Paths()) throws -> String {
        guard isValidUserName(user) else { throw InstallerError.invalidUserName(user) }
        guard isValidDigest(digest) else { throw InstallerError.invalidDigest(digest) }
        return "\(user) ALL=(root) NOPASSWD: sha256:\(digest) \(paths.helper) \(ScanlineHelper.argument)\n"
    }

    /// POSIX shell single-quoting.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The install script, to run as root (`/bin/sh`).
    public static func script(bundledHelper: String, expectedDigest: String, user: String,
                              paths: Paths = Paths()) throws -> String {
        guard isValidUserName(user) else { throw InstallerError.invalidUserName(user) }
        guard isValidDigest(expectedDigest) else { throw InstallerError.invalidDigest(expectedDigest) }
        let q = shellQuote
        let dir = (paths.helper as NSString).deletingLastPathComponent
        var lines = [
            "set -e",
            "H=\(q(paths.helper))",
            "NEW=\"$H.new\"",
            "RULE=$(/usr/bin/mktemp \(q(paths.tempDirectory + "/scanline-sudoers.XXXXXX")))",
            "trap '/bin/rm -f \"$RULE\" \"$NEW\"' EXIT",
        ]
        if paths.bootOutLegacyDaemon {
            lines.append("/bin/launchctl bootout system/\(paths.legacyLabel) 2>/dev/null || true")
        }
        lines += [
            "/bin/rm -f \(q(paths.legacyPlist))",
            "/bin/mkdir -p \(q(dir))",
            // 1. stage
            "/usr/bin/install -m 0755 -o \(q(paths.owner)) -g \(q(paths.group)) \(q(bundledHelper)) \"$NEW\"",
            // 2. hash the staged copy as root; it must be the file the app vetted
            "D=$(/usr/bin/shasum -a 256 \"$NEW\" | /usr/bin/cut -d' ' -f1)",
            "[ \"$D\" = \(q(expectedDigest)) ] || { echo 'The helper changed while it was being installed.' >&2; exit 3; }",
            // 3. rule from root's hash, checked before anything changes
            "/usr/bin/printf '%s ALL=(root) NOPASSWD: sha256:%s %s %s\\n' \(q(user)) \"$D\" \"$H\" \(q(ScanlineHelper.argument)) > \"$RULE\"",
            "/usr/sbin/visudo -cf \"$RULE\" >/dev/null",
            // 4. swap in binary and rule, back to back
            "/bin/mv -f \"$NEW\" \"$H\"",
            "/usr/bin/install -m 0440 -o \(q(paths.owner)) -g \(q(paths.group)) \"$RULE\" \(q(paths.sudoersFile))",
            "/bin/rm -f \(q(paths.legacySudoersFile))",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// AppleScript that runs `shell` as root after the standard macOS password prompt.
    public static func appleScript(running shell: String, prompt: String) -> String {
        func lit(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "do shell script \(lit(shell)) with administrator privileges with prompt \(lit(prompt))"
    }
}
