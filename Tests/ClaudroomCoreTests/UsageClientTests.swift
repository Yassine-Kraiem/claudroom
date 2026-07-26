import Testing
import Foundation
@testable import ClaudroomCore

/// Intercepts every request so no test touches the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serialized: the stub carries process-wide mutable state, so these must not
/// run concurrently with each other.
@Suite(.serialized)
struct UsageClientTests {
    private func stubbedClient() -> UsageClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return UsageClient(session: URLSession(configuration: cfg))
    }

    private let t0 = Date(timeIntervalSince1970: 1_785_000_000)

    private let usageBody = Data(#"{"seven_day":{"utilization":14.0,"resets_at":"2026-07-31T12:00:00+00:00"},"five_hour":{"utilization":31.0,"resets_at":"2026-07-25T11:00:00+00:00"},"limits":[]}"#.utf8)

    @Test func parsesA200Response() async throws {
        StubProtocol.status = 200
        StubProtocol.body = usageBody
        let snap = try await stubbedClient().fetchUsage(token: "x", now: t0)
        #expect(snap.weekly?.fraction == 0.14)
        #expect(snap.fiveHour?.fraction == 0.31)
        #expect(snap.observedAt == t0)
    }

    @Test func parsesProfileResponse() async throws {
        StubProtocol.status = 200
        StubProtocol.body = Data(#"{"organization":{"rate_limit_tier":"default_claude_max_5x"}}"#.utf8)
        let profile = try await stubbedClient().fetchProfile(token: "x")
        #expect(profile.tier == .max5x)
    }

    @Test func mapsUnauthorized() async {
        StubProtocol.status = 401
        StubProtocol.body = Data()
        await #expect(throws: UsageClientError.unauthorized) {
            _ = try await stubbedClient().fetchUsage(token: "x", now: t0)
        }
    }

    @Test func mapsForbiddenAsUnauthorized() async {
        StubProtocol.status = 403
        StubProtocol.body = Data()
        await #expect(throws: UsageClientError.unauthorized) {
            _ = try await stubbedClient().fetchUsage(token: "x", now: t0)
        }
    }

    @Test func mapsRateLimited() async {
        StubProtocol.status = 429
        StubProtocol.body = Data()
        await #expect(throws: UsageClientError.rateLimited) {
            _ = try await stubbedClient().fetchUsage(token: "x", now: t0)
        }
    }

    @Test func mapsServerError() async {
        StubProtocol.status = 503
        StubProtocol.body = Data()
        await #expect(throws: UsageClientError.server(503)) {
            _ = try await stubbedClient().fetchUsage(token: "x", now: t0)
        }
    }
}
