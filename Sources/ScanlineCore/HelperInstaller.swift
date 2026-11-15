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
        public var visudo = "/usr/sbin/visudo"
        /// Stop the old LaunchDaemon (helper v1). Off in tests.
        public var bootOutLegacyDaemon = true
        public init() {}
    }

    public enum InstallerError: Error, Equatable, CustomStringConvertible {
        case invalidDigest(String)
        public var description: String {
            switch self {
            case let .invalidDigest(d): "not a SHA-256 digest: \(d)"
            }
        }
    }

    public static func isValidDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }

    public static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The sudo rule: the user with this uid may run exactly this helper file (by digest) with
    /// its one argument. By uid (`#501`), not name: no name can be misread as `ALL` or an alias.
    public static func rule(uid: uid_t, digest: String, paths: Paths = Paths()) throws -> String {
        guard isValidDigest(digest) else { throw InstallerError.invalidDigest(digest) }
        return "#\(uid) ALL=(root) NOPASSWD: sha256:\(digest) \(paths.helper) \(ScanlineHelper.argument)\n"
    }

    /// POSIX shell single-quoting.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The install script, to run as root (`/bin/sh`).
    public static func script(bundledHelper: String, expectedDigest: String, uid: uid_t,
                              paths: Paths = Paths()) throws -> String {
        guard isValidDigest(expectedDigest) else { throw InstallerError.invalidDigest(expectedDigest) }
        let q = shellQuote
        let dir = (paths.helper as NSString).deletingLastPathComponent
        var lines = [
            "set -e",
            "umask 077",
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
            // 1. stage: only from a plain file, and readable by root alone until it checks out
            "S=\(q(bundledHelper))",
            "[ -f \"$S\" ] && [ ! -L \"$S\" ] || { echo 'The bundled helper is not a plain file.' >&2; exit 4; }",
            "/usr/bin/install -m 0700 -o \(q(paths.owner)) -g \(q(paths.group)) \"$S\" \"$NEW\"",
            // 2. hash the staged copy as root; it must be the file the app vetted
            "D=$(/usr/bin/shasum -a 256 \"$NEW\") || { echo 'Could not hash the helper.' >&2; exit 5; }",
            "D=${D%% *}",
            "[ \"$D\" = \(q(expectedDigest)) ] || { echo 'The helper changed while it was being installed.' >&2; exit 3; }",
            "/bin/chmod 0755 \"$NEW\"",
            // 3. rule from root's hash, checked before anything changes
            "/usr/bin/printf '%s ALL=(root) NOPASSWD: sha256:%s %s %s\\n' \(q("#\(uid)")) \"$D\" \"$H\" \(q(ScanlineHelper.argument)) > \"$RULE\"",
            "\(q(paths.visudo)) -cf \"$RULE\" >/dev/null",
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
