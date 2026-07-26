import Foundation

public enum UsageClientError: Error, Equatable, Sendable {
    case unauthorized
    case rateLimited
    case server(Int)
    case transport
}

public protocol UsageFetching: Sendable {
    func fetchUsage(token: String, now: Date) async throws -> UsageSnapshot
    func fetchProfile(token: String) async throws -> Profile
}

public struct UsageClient: UsageFetching {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    /// Undocumented endpoints; these headers mirror the Claude Code CLI's own.
    public static let betaHeader = "oauth-2025-04-20"
    public static let userAgent = "claude-cli/2.1.216 (external, cli)"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private func get(_ url: URL, token: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw UsageClientError.transport
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageClientError.transport
        }
        switch http.statusCode {
        case 200...299: return data
        case 401, 403:  throw UsageClientError.unauthorized
        case 429:       throw UsageClientError.rateLimited
        default:        throw UsageClientError.server(http.statusCode)
        }
    }

    public func fetchUsage(token: String, now: Date) async throws -> UsageSnapshot {
        try UsageDecoder.decode(data: try await get(Self.usageURL, token: token),
                                observedAt: now)
    }

    public func fetchProfile(token: String) async throws -> Profile {
        try ProfileDecoder.decode(data: try await get(Self.profileURL, token: token))
    }
}
