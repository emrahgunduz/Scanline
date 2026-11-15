/// What the sidebar should offer about the helper, if anything. Pure, so it can be tested.
public enum HelperBannerKind: Equatable, Sendable {
    case install, repair, secure, update, incompatible

    /// - Parameters:
    ///   - status: installed vs bundled helper (nil: not checked yet)
    ///   - problem: why the scanner isn't connected right now, if it isn't
    ///   - needsAccess: no helper in use (vendor driver or nothing)
    ///   - dismissed: the user chose Not Now for this bundled helper
    public static func decide(status: HelperStatus?, problem: ConnectProblem?, needsAccess: Bool,
                              dismissed: Bool) -> HelperBannerKind? {
        // A build without a bundled helper can't install one: say nothing.
        if status == .bundleMissing { return nil }
        // What the scanner just reported wins over the static check.
        switch problem {
        case .helperOutdated?: return .incompatible
        case .helperNotAuthorised?: return .repair
        default: break
        }
        switch status {
        case .notInstalled?: return .install
        case .ruleMissing?: return .repair
        case .unpinned?: return dismissed ? nil : .secure
        case .outdated?: return dismissed ? nil : .update
        default: return needsAccess ? .install : nil
        }
    }
}
