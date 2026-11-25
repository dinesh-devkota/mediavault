import CryptoKit
import Foundation
import Security

enum DropboxClientError: Error {
    case invalidConfiguration, invalidAuthorization, invalidResponse, http(Int)
}

private final class DropboxRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct DropboxClient: Sendable {
    struct Authorization: Sendable {
        let url: URL
        fileprivate let verifier: String
        fileprivate let state: String
        fileprivate let deadline: ContinuousClock.Instant
    }

    struct Credentials: Decodable, Sendable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let account_id: String?
    }

    struct Entry: Decodable, Sendable {
        let id: String?
        let name: String
        let path_lower: String?
        let path_display: String?
        let kind: String
        let size: Int64?

        enum CodingKeys: String, CodingKey {
            case id, name, path_lower, path_display, size
            case kind = ".tag"
        }
    }

    private struct Page: Decodable {
        let entries: [Entry]
        let cursor: String
        let has_more: Bool
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config, delegate: DropboxRedirectDelegate(), delegateQueue: nil)
    }()
    private let appKey: String
    private let callback: URL

    init(appKey: String, callback: URL) throws {
        guard !appKey.isEmpty, callback.scheme == "https", callback.host?.isEmpty == false,
              callback.user == nil, callback.password == nil, callback.query == nil, callback.fragment == nil else {
            throw DropboxClientError.invalidConfiguration
        }
        self.appKey = appKey
        self.callback = callback
    }

    func beginAuthorization() throws -> Authorization {
        let state = try Self.randomString()
        let verifier = try Self.randomString()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var url = URLComponents()
        url.scheme = "https"
        url.host = "www.dropbox.com"
        url.path = "/oauth2/authorize"
        url.queryItems = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: callback.absoluteString),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "scope", value: "files.metadata.read files.content.read"),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
        ]
        guard let target = url.url else { throw DropboxClientError.invalidConfiguration }
        return Authorization(url: target, verifier: verifier, state: state, deadline: ContinuousClock.now.advanced(by: .seconds(600)))
    }

    func completeAuthorization(_ authorization: Authorization, callback response: URL) async throws -> Credentials {
        guard ContinuousClock.now < authorization.deadline,
              var parts = URLComponents(url: response, resolvingAgainstBaseURL: false),
              parts.fragment == nil else { throw DropboxClientError.invalidAuthorization }
        let fields = parts.queryItems ?? []
        parts.query = nil
        let state = fields.filter { $0.name == "state" }
        let code = fields.filter { $0.name == "code" }
        guard parts.url == callback, !fields.contains(where: { $0.name == "error" }),
              state.count == 1, state[0].value == authorization.state,
              code.count == 1, let value = code[0].value, !value.isEmpty else {
            throw DropboxClientError.invalidAuthorization
        }
        return try await token([
            "grant_type": "authorization_code", "code": value,
            "redirect_uri": callback.absoluteString, "code_verifier": authorization.verifier,
        ])
    }

    func refresh(_ refreshToken: String) async throws -> Credentials {
        try await token(["grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    func revoke(accessToken: String) async throws {
        _ = try await jsonRequest(path: "auth/token/revoke", accessToken: accessToken, arguments: nil)
    }

    func listFolder(path: String, accessToken: String, onPage: ([Entry]) async throws -> Void) async throws {
        var page = try JSONDecoder().decode(Page.self, from: await jsonRequest(
            path: "files/list_folder", accessToken: accessToken, arguments: ["path": path]))
        var seen: Set<String> = []
        while true {
            try Task.checkCancellation()
            if page.has_more {
                guard !page.cursor.isEmpty, seen.count < 10_000, seen.insert(page.cursor).inserted else {
                    throw DropboxClientError.invalidResponse
                }
            }
            try await onPage(page.entries)
            guard page.has_more else { return }
            page = try JSONDecoder().decode(Page.self, from: await jsonRequest(
                path: "files/list_folder/continue", accessToken: accessToken, arguments: ["cursor": page.cursor]))
        }
    }

    private func token(_ fields: [String: String]) async throws -> Credentials {
        var form = URLComponents()
        form.queryItems = (fields.merging(["client_id": appKey]) { existing, _ in existing }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let body = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") else {
            throw DropboxClientError.invalidConfiguration
        }
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return try JSONDecoder().decode(Credentials.self, from: await Self.send(request))
    }

    private func jsonRequest(path: String, accessToken: String, arguments: [String: String]?) async throws -> Data {
        guard !accessToken.isEmpty, accessToken.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw DropboxClientError.invalidAuthorization
        }
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/" + path)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let arguments {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(arguments)
        }
        return try await Self.send(request)
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let limit = 8 * 1024 * 1024
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= Int64(limit) else {
            throw DropboxClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw DropboxClientError.http(http.statusCode) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw DropboxClientError.invalidResponse }
            data.append(byte)
        }
        return data
    }

    private static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DropboxClientError.invalidAuthorization
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
