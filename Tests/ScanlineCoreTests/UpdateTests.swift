import Foundation
import Testing
@testable import ScanlineCore

@Test func versionsParseAndCompareNumerically() throws {
    let v = { (s: String) in try #require(ReleaseVersion(s)) }
    #expect(try v("v1.0.10") > v("1.0.9"))
    #expect(try v("1.0") == v("1.0.0"))
    #expect(try v("V2") == v("2.0.0.0"))
    #expect(try v("1.0.1-2-g8744c32") == v("1.0.1"))
    #expect(try v("1.0.1+meta") == v("1.0.1"))
    #expect(try v("v9.9.9").description == "9.9.9")
    #expect(try v("2").description == "2")
    for bad in ["", "v", "1..2", "1.2.3.4.5", "1.x", "-1.0", "１.0", "latest"] { #expect(ReleaseVersion(bad) == nil, "\(bad)") }
}

@Test func isUpdateOnlyForANewerParsableRelease() {
    #expect(UpdateCheck.isUpdate(latestTag: "v1.0.5", current: "1.0.4"))
    #expect(!UpdateCheck.isUpdate(latestTag: "v1.0.4", current: "1.0.4"))
    #expect(!UpdateCheck.isUpdate(latestTag: "v1.0.3", current: "1.0.4"))
    #expect(!UpdateCheck.isUpdate(latestTag: "nightly", current: "1.0.4"))
    #expect(!UpdateCheck.isUpdate(latestTag: "v9.0.0", current: "garbage"))
}

@Test func buildInfoFromInfoPlist() {
    let release = AppBuildInfo.from(infoDictionary: ["CFBundleShortVersionString": "1.0.7", "CFBundleVersion": "7", "ScanlineBuildKind": "release"])
    #expect(release.kind == .release)
    #expect(release.displayVersion == "1.0.7 (7)")
    let dev = AppBuildInfo.from(infoDictionary: ["CFBundleShortVersionString": "1.0.1", "ScanlineGitDescribe": "v1.0.1-2-g8744c32"])
    #expect(dev.kind == .dev)                                   // missing kind: dev, never nags
    #expect(dev.displayVersion == "1.0.1-dev (v1.0.1-2-g8744c32)")
    #expect(AppBuildInfo.from(infoDictionary: ["ScanlineBuildKind": "weird"]).kind == .dev)
    #expect(AppBuildInfo.from(infoDictionary: nil).version == "0.0.0")
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func interpretResponses() {
    let body = Data(#"{"tag_name":"v1.0.7","draft":false,"prerelease":false,"published_at":"2026-11-15T10:00:00Z","html_url":"https://evil.example"}"#.utf8)
    guard case let .release(r, etag) = UpdateCheck.interpret(status: 200, headers: ["ETag": "W/\"abc\""], body: body, now: now) else {
        Issue.record("expected a release"); return
    }
    #expect(r.tag == "v1.0.7")
    #expect(r.publishedAt != nil)
    #expect(etag == "W/\"abc\"")
    #expect(UpdateCheck.interpret(status: 304, headers: [:], body: Data(), now: now) == .notModified)
    #expect(UpdateCheck.interpret(status: 404, headers: [:], body: Data(), now: now) == .unavailable)
    let pre = Data(#"{"tag_name":"v2.0.0","prerelease":true}"#.utf8)
    #expect(UpdateCheck.interpret(status: 200, headers: [:], body: pre, now: now) != .release(LatestRelease(tag: "v2.0.0"), etag: nil))
    if case .release = UpdateCheck.interpret(status: 200, headers: [:], body: pre, now: now) { Issue.record("prerelease accepted") }
    if case .release = UpdateCheck.interpret(status: 200, headers: [:], body: Data("nope".utf8), now: now) { Issue.record("junk accepted") }
}

@Test func rateLimitsBackOff() {
    let reset = now.addingTimeInterval(1200)
    #expect(UpdateCheck.interpret(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(Int(reset.timeIntervalSince1970))"], body: Data(), now: now)
            == .rateLimited(until: reset))
    #expect(UpdateCheck.interpret(status: 429, headers: ["Retry-After": "60"], body: Data(), now: now) == .rateLimited(until: now.addingTimeInterval(60)))
    #expect(UpdateCheck.interpret(status: 429, headers: [:], body: Data(), now: now) == .rateLimited(until: now.addingTimeInterval(3600)))
    #expect(UpdateCheck.interpret(status: 403, headers: ["X-RateLimit-Remaining": "0"], body: Data(), now: now) == .rateLimited(until: now.addingTimeInterval(3600)))
    #expect(UpdateCheck.interpret(status: 403, headers: [:], body: Data(), now: now) == .failed("HTTP 403"))
    #expect(UpdateCheck.interpret(status: 500, headers: [:], body: Data(), now: now) == .failed("HTTP 500"))
}

@Test func checksAreDueOncePerInterval() {
    let day = UpdateCheck.interval
    #expect(UpdateCheck.isDue(now: now, lastCheck: nil, nextAllowed: nil))
    #expect(!UpdateCheck.isDue(now: now, lastCheck: now.addingTimeInterval(-day + 60), nextAllowed: nil))
    #expect(UpdateCheck.isDue(now: now, lastCheck: now.addingTimeInterval(-day), nextAllowed: nil))
    #expect(!UpdateCheck.isDue(now: now, lastCheck: nil, nextAllowed: now.addingTimeInterval(60)))   // rate limited
    #expect(UpdateCheck.isDue(now: now, lastCheck: now.addingTimeInterval(3600), nextAllowed: nil))   // clock went back
}

@Test func releasePageIsBuiltFromAFixedBase() {
    #expect(UpdateCheck.releasePageURL(tag: "v1.0.7")?.absoluteString == "https://github.com/emrahgunduz/Scanline/releases/tag/v1.0.7")
    let odd = UpdateCheck.releasePageURL(tag: "../../evil?x=1#y")?.absoluteString ?? ""
    #expect(odd.hasPrefix("https://github.com/emrahgunduz/Scanline/releases/tag/"))
    #expect(!odd.contains("?") && !odd.contains("#") && !odd.dropFirst("https://".count).contains("/../"))
}

private final class Captured: @unchecked Sendable {
    let lock = NSLock(); var requests: [URLRequest] = []
}

@Test func checkerSendsOnlyGenericHeaders() async throws {
    let seen = Captured()
    let checker = UpdateChecker(url: UpdateCheck.endpoint) { req in
        seen.lock.withLock { seen.requests.append(req) }
        let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"e1\""])!
        return (Data(#"{"tag_name":"v1.0.9"}"#.utf8), resp)
    }
    #expect(await checker.check(etag: nil, now: now) == .release(LatestRelease(tag: "v1.0.9"), etag: "\"e1\""))
    _ = await checker.check(etag: "\"e1\"", now: now)
    let (first, second) = seen.lock.withLock { (seen.requests[0], seen.requests[1]) }
    #expect(first.value(forHTTPHeaderField: "User-Agent") == "Scanline-update-check")
    #expect(first.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(first.value(forHTTPHeaderField: "If-None-Match") == nil)
    #expect(second.value(forHTTPHeaderField: "If-None-Match") == "\"e1\"")
    #expect(first.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(first.url?.query == nil)
    #expect(first.httpMethod == "GET")
    #expect(Set(first.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []) == ["user-agent", "accept", "accept-language", "x-github-api-version"])
}

@Test func checkerReportsTransportErrors() async {
    let checker = UpdateChecker(url: UpdateCheck.endpoint) { _ in throw URLError(.notConnectedToInternet) }
    if case .failed = await checker.check(etag: nil, now: now) {} else { Issue.record("expected failure") }
}

@Test func updateURLCanBeOverriddenForTesting() {
    #expect(UpdateChecker.defaultURL(environment: [:]) == UpdateCheck.endpoint)
    #expect(UpdateChecker.defaultURL(environment: ["SCANLINE_UPDATE_URL": "file:///tmp/x.json"]).isFileURL)
}
