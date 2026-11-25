import Foundation

enum OneDriveError: LocalizedError {
    case invalidClient, invalidResponse, expired, denied, rejected(Int)

    var errorDescription: String? {
        switch self {
        case .invalidClient: return "Configure a Microsoft public client application ID."
        case .invalidResponse: return "Microsoft returned an invalid OneDrive response."
        case .expired: return "The Microsoft sign-in code expired."
        case .denied: return "Microsoft sign-in was declined."
        case .rejected(let status): return "Microsoft rejected the request (HTTP \(status))."
        }
    }
}

private final class OneDriveRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct OneDriveClient: Sendable {
    struct Challenge: Decodable, Sendable {
        let user_code: String
        let verification_uri: URL
        fileprivate let device_code: String
        fileprivate let expires_in: Int
        fileprivate let interval: Int?
    }

    struct Credentials: Decodable, Sendable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    struct Entry: Decodable, Sendable {
        struct Folder: Decodable, Sendable { let childCount: Int? }
        struct File: Decodable, Sendable { let mimeType: String? }
        let id: String
        let name: String
        let size: Int64?
        let folder: Folder?
        let file: File?
    }

    private struct GraphPage: Decodable {
        let value: [Entry]
        let next: URL?
        enum CodingKeys: String, CodingKey { case value; case next = "@odata.nextLink" }
    }

    private struct OAuthError: Decodable { let error: String }
    private static let scope = "https://graph.microsoft.com/Files.Read offline_access"
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config, delegate: OneDriveRedirectDelegate(), delegateQueue: nil)
    }()
    private let clientID: String

    init(clientID: String) throws {
        guard let id = UUID(uuidString: clientID) else { throw OneDriveError.invalidClient }
        self.clientID = id.uuidString.lowercased()
    }

    func beginSignIn() async throws -> Challenge {
        let (data, status) = try await oauth("devicecode", fields: ["scope": Self.scope])
        guard status == 200 else { throw OneDriveError.rejected(status) }
        let result = try JSONDecoder().decode(Challenge.self, from: data)
        guard result.verification_uri.scheme == "https", result.verification_uri.host == "microsoft.com" ||
                result.verification_uri.host == "www.microsoft.com" || result.verification_uri.host == "login.microsoftonline.com",
              result.verification_uri.user == nil, result.verification_uri.password == nil,
              (1...3600).contains(result.expires_in), !result.device_code.isEmpty, !result.user_code.isEmpty else {
            throw OneDriveError.invalidResponse
        }
        return result
    }

    func completeSignIn(_ challenge: Challenge) async throws -> Credentials {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(challenge.expires_in))
        var interval = min(max(challenge.interval ?? 5, 1), 60)
        while clock.now < deadline {
            try await clock.sleep(until: min(clock.now.advanced(by: .seconds(interval)), deadline))
            guard clock.now < deadline else { break }
            let (data, status) = try await oauth("token", fields: [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": challenge.device_code,
            ])
            if status == 200 { return try JSONDecoder().decode(Credentials.self, from: data) }
            switch (try? JSONDecoder().decode(OAuthError.self, from: data))?.error {
            case "authorization_pending": continue
            case "slow_down": interval = min(interval + 5, 3600)
            case "authorization_declined": throw OneDriveError.denied
            case "expired_token": throw OneDriveError.expired
            default: throw OneDriveError.rejected(status)
            }
        }
        throw OneDriveError.expired
    }

    func refresh(_ refreshToken: String) async throws -> Credentials {
        let (data, status) = try await oauth("token", fields: [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "scope": Self.scope,
        ])
        guard status == 200 else { throw OneDriveError.rejected(status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    func listChildren(folderID: String? = nil, accessToken: String, onPage: ([Entry]) async throws -> Void) async throws {
        var endpoint = URL(string: "https://graph.microsoft.com/v1.0/me/drive")!
        if let folderID {
            guard !folderID.isEmpty, folderID.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                    $0 == 33 || $0 == 45 || $0 == 95
            }) else { throw OneDriveError.invalidResponse }
            endpoint.appendPathComponent("items")
            endpoint.appendPathComponent(folderID)
        } else {
            endpoint.appendPathComponent("root")
        }
        endpoint.appendPathComponent("children")
        var next: URL? = endpoint
        var seen: Set<URL> = []
        while let url = next {
            try Task.checkCancellation()
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.scheme == "https", parts.host == "graph.microsoft.com", parts.port == nil,
                  parts.user == nil, parts.password == nil, parts.fragment == nil, parts.path == endpoint.path,
                  seen.count < 10_000, seen.insert(url).inserted,
                  !accessToken.isEmpty, accessToken.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw OneDriveError.invalidResponse
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, status) = try await Self.send(request)
            guard status == 200 else { throw OneDriveError.rejected(status) }
            let page = try JSONDecoder().decode(GraphPage.self, from: data)
            try await onPage(page.value)
            next = page.next
        }
    }

    private func oauth(_ path: String, fields: [String: String]) async throws -> (Data, Int) {
        let base = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0")!
        var request = URLRequest(url: base.appendingPathComponent(path))
        var form = URLComponents()
        form.queryItems = (fields.merging(["client_id": clientID]) { existing, _ in existing }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let body = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") else {
            throw OneDriveError.invalidResponse
        }
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return try await Self.send(request)
    }

    private static func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let limit = 8 * 1024 * 1024
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= Int64(limit) else {
            throw OneDriveError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw OneDriveError.invalidResponse }
            data.append(byte)
        }
        return (data, http.statusCode)
    }
}
