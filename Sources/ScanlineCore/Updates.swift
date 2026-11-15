import Foundation

// "Is there a newer Scanline?" One anonymous GET to GitHub's latest-release endpoint. Nothing is
// downloaded or installed; the app only links to the release page. The parsing, comparison and
// timing rules are pure so they can be tested without the network.

/// A numeric version such as 1.0.7 (a leading "v" and any "-…"/"+…" suffix are ignored).
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]   // always 4 parts, zero-padded, for comparing
    private let written: Int  // how many parts the text had, for display

    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = s[..<cut] }
        let fields = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(fields.count) else { return nil }
        var parts: [Int] = []
        for f in fields {
            guard !f.isEmpty, f.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(f) else { return nil }
            parts.append(n)
        }
        self.written = parts.count
        self.parts = parts + Array(repeating: 0, count: 4 - parts.count)
    }

    public static func == (a: ReleaseVersion, b: ReleaseVersion) -> Bool { a.parts == b.parts }
    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    /// "1.0.7" for "v1.0.7" (as written, without the "v" or a suffix).
    public var description: String { parts.prefix(written).map(String.init).joined(separator: ".") }
}

public enum BuildKind: String, Sendable { case release, dev }

/// What the running build says about itself (stamped into Info.plist by build-app.sh).
public struct AppBuildInfo: Sendable, Equatable {
    public var version: String
    public var build: String?
    public var kind: BuildKind
    public var describe: String?

    public init(version: String, build: String? = nil, kind: BuildKind, describe: String? = nil) {
        self.version = version; self.build = build; self.kind = kind; self.describe = describe
    }

    /// A missing or unknown kind means dev, so unstamped builds never nag.
    public static func from(infoDictionary info: [String: Any]?) -> AppBuildInfo {
        let info = info ?? [:]
        return AppBuildInfo(version: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
                            build: info["CFBundleVersion"] as? String,
                            kind: (info["ScanlineBuildKind"] as? String).flatMap(BuildKind.init(rawValue:)) ?? .dev,
                            describe: info["ScanlineGitDescribe"] as? String)
    }

    /// "1.0.7 (7)" for releases, "1.0.1-dev (v1.0.1-2-g8744c32)" for dev builds.
    public var displayVersion: String {
        switch kind {
        case .release: build.map { "\(version) (\($0))" } ?? version
        case .dev: "\(version)-dev" + (describe.map { " (\($0))" } ?? "")
        }
    }
}

public struct LatestRelease: Codable, Sendable, Equatable {
    public var tag: String
    public var publishedAt: Date?
    public init(tag: String, publishedAt: Date? = nil) { self.tag = tag; self.publishedAt = publishedAt }
}

public enum UpdateCheck {
    public static let repository = "emrahgunduz/Scanline"
    public static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let interval: TimeInterval = 24 * 3600
    public static let userAgent = "Scanline-update-check"

    public enum Result: Equatable, Sendable {
        case release(LatestRelease, etag: String?)
        /// 304: the release is the one we saw last time.
        case notModified
        /// 404: no public release (the repo is private or has none). Silent.
        case unavailable
        case rateLimited(until: Date)
        case failed(String)
    }

    /// True only when both sides parse and the latest release is newer.
    public static func isUpdate(latestTag: String, current: String) -> Bool {
        guard let latest = ReleaseVersion(latestTag), let now = ReleaseVersion(current) else { return false }
        return latest > now
    }

    public static func interpret(status: Int, headers: [String: String], body: Data, now: Date) -> Result {
        let h = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        switch status {
        case 200:
            struct Wire: Decodable {
                let tag_name: String
                let draft: Bool?
                let prerelease: Bool?
                let published_at: String?
            }
            guard let w = try? JSONDecoder().decode(Wire.self, from: body), !w.tag_name.isEmpty else {
                return .failed("unexpected response")
            }
            if w.draft == true || w.prerelease == true { return .failed("not a final release") }
            let published = w.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
            return .release(LatestRelease(tag: w.tag_name, publishedAt: published), etag: h["etag"])
        case 304:
            return .notModified
        case 404:
            return .unavailable
        case 403, 429:
            if let retry = h["retry-after"].flatMap(TimeInterval.init) { return .rateLimited(until: now.addingTimeInterval(retry)) }
            guard status == 429 || h["x-ratelimit-remaining"] == "0" else { return .failed("HTTP 403") }
            if let reset = h["x-ratelimit-reset"].flatMap(TimeInterval.init) {
                return .rateLimited(until: max(now, Date(timeIntervalSince1970: reset)))
            }
            return .rateLimited(until: now.addingTimeInterval(3600))
        default:
            return .failed("HTTP \(status)")
        }
    }

    /// Whether an automatic check should run now.
    public static func isDue(now: Date, lastCheck: Date?, nextAllowed: Date?, interval: TimeInterval = interval) -> Bool {
        if let nextAllowed, now < nextAllowed { return false }
        guard let lastCheck else { return true }
        // A clock set backwards shouldn't stop checks for good.
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }

    /// The release page, built from a fixed base; nothing from the response body is opened.
    public static func releasePageURL(tag: String) -> URL? {
        guard let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))),
              !encoded.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/tag/\(encoded)")
    }
}

/// Fetches the latest release. The fetch is injectable for tests.
public struct UpdateChecker: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public var url: URL
    public var fetch: Fetch

    public init(url: URL = UpdateChecker.defaultURL(), fetch: @escaping Fetch = UpdateChecker.defaultFetch) {
        self.url = url; self.fetch = fetch
    }

    /// `SCANLINE_UPDATE_URL` replaces the endpoint for manual testing (e.g. a file:// fixture).
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["SCANLINE_UPDATE_URL"].flatMap(URL.init(string:)) ?? UpdateCheck.endpoint
    }

    public func request(etag: String?) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        r.httpMethod = "GET"
        r.httpShouldHandleCookies = false
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue(UpdateCheck.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("en", forHTTPHeaderField: "Accept-Language")   // not the user's locale
        if let etag, !etag.isEmpty { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return r
    }

    public func check(etag: String?, now: Date = Date()) async -> UpdateCheck.Result {
        do {
            let (data, response) = try await fetch(request(etag: etag))
            guard let http = response as? HTTPURLResponse else {
                // file:// fixtures for manual testing: treat a readable body as a 200.
                return UpdateCheck.interpret(status: 200, headers: [:], body: data, now: now)
            }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { headers[k] = v } }
            return UpdateCheck.interpret(status: http.statusCode, headers: headers, body: data, now: now)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// No cookies, no cache, no stored credentials.
    public static let defaultFetch: Fetch = { request in
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
}
