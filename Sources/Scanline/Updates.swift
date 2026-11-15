import AppKit
import Observation
import ScanlineCore

/// Checks GitHub once a day for a newer release and offers a link to it. Nothing is installed.
@MainActor @Observable
final class UpdateController {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(Date)
        /// No public release (the repository is private or has none).
        case unavailable(Date)
        case rateLimited(until: Date)
        case failed(Date, String)
    }

    let build = AppBuildInfo.from(infoDictionary: Bundle.main.infoDictionary)
    /// Persisted. On by default for release builds, off for dev builds.
    var enabled: Bool { didSet { store(enabled, "update.enabled"); if loaded { schedule() } } }
    private(set) var status: Status = .idle
    /// The newest release seen, if it is newer than this build.
    private(set) var available: LatestRelease?
    private(set) var dismissedTag: String? { didSet { store(dismissedTag, "update.dismissedTag") } }

    // Cache (UserDefaults when persistent): a 304 needs the tag from the last full reply.
    @ObservationIgnored private var etag: String? { didSet { store(etag, "update.etag") } }
    @ObservationIgnored private var latestTag: String? { didSet { store(latestTag, "update.latestTag") } }
    @ObservationIgnored private var lastCheck: Date? { didSet { store(lastCheck, "update.lastCheck") } }
    @ObservationIgnored private var nextAllowed: Date? { didSet { store(nextAllowed, "update.nextAllowed") } }

    @ObservationIgnored private let persistent: Bool
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let checker = UpdateChecker()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var inFlight = false
    /// didSet runs for assignments in init too; only store what changes after loading.
    @ObservationIgnored private var loaded = false

    /// `persistent` false (simulator, folder override): no automatic checks and nothing stored.
    init(persistent: Bool) {
        self.persistent = persistent
        let d = UserDefaults.standard
        enabled = persistent ? (d.object(forKey: "update.enabled") as? Bool ?? (build.kind == .release)) : false
        if persistent {
            dismissedTag = d.string(forKey: "update.dismissedTag")
            etag = d.string(forKey: "update.etag")
            latestTag = d.string(forKey: "update.latestTag")
            lastCheck = d.object(forKey: "update.lastCheck") as? Date
            nextAllowed = d.object(forKey: "update.nextAllowed") as? Date
        }
        apply(tag: latestTag)
        if let lastCheck, available == nil, latestTag != nil { status = .upToDate(lastCheck) }
        loaded = true
        schedule()
    }

    /// Whether the sidebar banner shows: an update this user hasn't waved away.
    var showsBanner: Bool { available.map { $0.tag != dismissedTag } ?? false }

    func dismissBanner() { dismissedTag = available?.tag }

    func openRelease() {
        guard let tag = available?.tag, let url = UpdateCheck.releasePageURL(tag: tag) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The "Check Now" button: ignores the daily interval, but not a rate-limit back-off.
    func checkNow() {
        if let nextAllowed, Date() < nextAllowed { status = .rateLimited(until: nextAllowed); return }
        Task { await check() }
    }

    private func schedule() {
        loop?.cancel(); loop = nil
        guard persistent, enabled else { return }
        // Wake hourly and check when a day has passed: survives sleep without a scheduler.
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if UpdateCheck.isDue(now: Date(), lastCheck: self.lastCheck, nextAllowed: self.nextAllowed) {
                    await self.check()
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func check() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        status = .checking
        var result = await checker.check(etag: etag)
        if result == .notModified && latestTag == nil {
            etag = nil                                   // cache lost its tag: ask again in full
            result = await checker.check(etag: nil)
        }
        let now = Date()
        switch result {
        case let .release(release, newEtag):
            etag = newEtag
            latestTag = release.tag
            lastCheck = now
            nextAllowed = nil
            apply(tag: release.tag)
            status = available == nil ? .upToDate(now) : .idle
        case .notModified:
            lastCheck = now
            nextAllowed = nil
            apply(tag: latestTag)
            status = available == nil ? .upToDate(now) : .idle
        case .unavailable:
            etag = nil; latestTag = nil
            lastCheck = now
            apply(tag: nil)
            status = .unavailable(now)
        case let .rateLimited(until):
            nextAllowed = until
            status = .rateLimited(until: until)
        case let .failed(message):
            // Try again in an hour rather than a day; the loop re-evaluates hourly anyway.
            nextAllowed = now.addingTimeInterval(3600)
            status = .failed(now, message)
        }
    }

    private func apply(tag: String?) {
        if let tag, UpdateCheck.isUpdate(latestTag: tag, current: build.version) {
            available = LatestRelease(tag: tag)
        } else {
            available = nil
        }
    }

    private func store(_ value: Any?, _ key: String) {
        guard persistent, loaded else { return }
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
