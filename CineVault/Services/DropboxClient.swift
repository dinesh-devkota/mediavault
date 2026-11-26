import CryptoKit
import Foundation
import Security

enum DropboxClientError: LocalizedError {
    case invalidConfiguration, invalidAuthorization, invalidResponse, http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Enter a valid registered Dropbox app key."
        case .invalidAuthorization: "This Dropbox approval is invalid or expired. Start a new approval."
        case .invalidResponse: "Dropbox returned an invalid response."
        case .http(400): "Dropbox rejected this request. Check the app registration or start a new approval."
        case .http(401), .http(403): "Dropbox denied access. Reconnect the original account from Sources."
        case .http(409): "This Dropbox file or folder may have moved or become unavailable."
        case .http(429): "Dropbox is limiting requests. Try again shortly."
        case .http: "Dropbox could not complete this request. Try again."
        }
    }
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
        fileprivate let appKey: String
        fileprivate let callback: URL?
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
        let revision: String?
        let downloadable: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, path_lower, path_display, size
            case kind = ".tag"
            case revision = "rev"
            case downloadable = "is_downloadable"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decodeIfPresent(String.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            path_lower = try values.decodeIfPresent(String.self, forKey: .path_lower)
            path_display = try values.decodeIfPresent(String.self, forKey: .path_display)
            kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "file"
            size = try values.decodeIfPresent(Int64.self, forKey: .size)
            revision = try values.decodeIfPresent(String.self, forKey: .revision)
            downloadable = try values.decodeIfPresent(Bool.self, forKey: .downloadable) ?? true
        }
    }

    private struct Page: Decodable {
        let entries: [Entry]
        let cursor: String
        let has_more: Bool
    }

    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config, delegate: DropboxRedirectDelegate(), delegateQueue: nil)
    }()
    private let appKey: String
    private let callback: URL?
    private let session: URLSession
    #if DEBUG && os(iOS) && targetEnvironment(simulator)
    private let usePhoneFixture: Bool
    #endif

    init(appKey: String, callback: URL? = nil, session: URLSession? = nil) throws {
        guard Self.isAppKey(appKey) else { throw DropboxClientError.invalidConfiguration }
        if let callback {
            guard callback.scheme == "https", callback.host?.isEmpty == false,
                  callback.user == nil, callback.password == nil, callback.query == nil, callback.fragment == nil else {
                throw DropboxClientError.invalidConfiguration
            }
        }
        self.appKey = appKey
        self.callback = callback
        self.session = session ?? Self.defaultSession
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
        usePhoneFixture = session == nil && ProcessInfo.processInfo.arguments.contains("--ui-test-dropbox")
        #endif
    }

    func beginAuthorization() throws -> Authorization {
        let state = try Self.randomString()
        let verifier = try Self.randomString()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var url = URLComponents()
        url.scheme = "https"
        url.host = "www.dropbox.com"
        url.path = "/oauth2/authorize"
        var query: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "scope", value: "files.metadata.read files.content.read"),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
        ]
        if let callback { query.append(URLQueryItem(name: "redirect_uri", value: callback.absoluteString)) }
        url.queryItems = query
        guard let target = url.url else { throw DropboxClientError.invalidConfiguration }
        return Authorization(url: target, appKey: appKey, callback: callback, verifier: verifier, state: state,
                             deadline: ContinuousClock.now.advanced(by: .seconds(600)))
    }

    func completeAuthorization(_ authorization: Authorization, callback response: URL) async throws -> Credentials {
        guard accepts(authorization), let callback,
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

    /// The browser displays a code when the initial request omits the redirect URI.
    func completeManualAuthorization(_ authorization: Authorization, code: String) async throws -> Credentials {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accepts(authorization), callback == nil, (1...2048).contains(code.utf8.count),
              code.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw DropboxClientError.invalidAuthorization
        }
        return try await token(["grant_type": "authorization_code", "code": code, "code_verifier": authorization.verifier])
    }

    private func accepts(_ authorization: Authorization) -> Bool {
        authorization.appKey == appKey && authorization.callback == callback && ContinuousClock.now < authorization.deadline
    }

    func refresh(_ refreshToken: String) async throws -> Credentials {
        try await token(["grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    func revoke(accessToken: String) async throws {
        _ = try await jsonRequest(path: "auth/token/revoke", accessToken: accessToken, arguments: nil)
    }

    func listFolder(path: String, accessToken: String, authorize: () throws -> Void = {},
                    onPage: ([Entry]) async throws -> Void) async throws {
        try authorize()
        var page = try JSONDecoder().decode(Page.self, from: await jsonRequest(
            path: "files/list_folder", accessToken: accessToken, arguments: ["path": path]))
        var seen: Set<String> = []
        while true {
            try Task.checkCancellation()
            try authorize()
            if page.has_more {
                guard !page.cursor.isEmpty, seen.count < 10_000, seen.insert(page.cursor).inserted else {
                    throw DropboxClientError.invalidResponse
                }
            }
            try await onPage(page.entries)
            guard page.has_more else { return }
            try authorize()
            page = try JSONDecoder().decode(Page.self, from: await jsonRequest(
                path: "files/list_folder/continue", accessToken: accessToken, arguments: ["cursor": page.cursor]))
        }
    }

    /// Dropbox file IDs keep reads tied to the catalog entry when a file is renamed or moved.
    func read(fileID: String, offset: Int64, length: Int, accessToken: String, expectedSize: Int64? = nil,
              revision: String? = nil, authorize: () throws -> Void = {}) async throws -> Data {
        guard Self.isItemID(fileID),
              offset >= 0, (1...8 * 1024 * 1024).contains(length),
              offset <= Int64.max - Int64(length) else { throw DropboxClientError.invalidConfiguration }
        let end = offset + Int64(length) - 1
        var request = try authorizedRequest(
            url: URL(string: "https://content.dropboxapi.com/2/files/download")!,
            accessToken: accessToken)
        request.httpMethod = "POST"
        let arguments = try JSONEncoder().encode(["path": fileID])
        request.setValue(String(decoding: arguments, as: UTF8.self), forHTTPHeaderField: "Dropbox-API-Arg")
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        try authorize()
        let (bytes, response) = try await session.bytes(for: requestForTransport(request))
        defer { bytes.task.cancel() }
        try authorize()
        guard let http = response as? HTTPURLResponse else { throw DropboxClientError.invalidResponse }
        guard http.statusCode == 206 else { throw DropboxClientError.http(http.statusCode) }
        guard let header = http.value(forHTTPHeaderField: "Content-Range"),
              Self.matchesRange(header, offset: offset, end: end, expectedSize: expectedSize),
              response.expectedContentLength < 0 || response.expectedContentLength == Int64(length),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            throw DropboxClientError.invalidResponse
        }
        if let revision {
            guard let raw = http.value(forHTTPHeaderField: "Dropbox-API-Result"),
                  let metadata = try? JSONDecoder().decode(Entry.self, from: Data(raw.utf8)),
                  metadata.id == fileID, metadata.revision == revision, metadata.size == expectedSize else {
                throw CloudFileError.invalidRange
            }
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < length else { throw DropboxClientError.invalidResponse }
            if data.count.isMultiple(of: 32768) { try authorize() }
            data.append(byte)
        }
        try authorize()
        guard data.count == length else { throw DropboxClientError.invalidResponse }
        return data
    }

    private static func matchesRange(_ header: String, offset: Int64, end: Int64, expectedSize: Int64?) -> Bool {
        let prefix = "bytes \(offset)-\(end)/"
        guard header.hasPrefix(prefix), let total = Int64(header.dropFirst(prefix.count)) else { return false }
        return total > end && header == prefix + String(total) && (expectedSize == nil || total == expectedSize)
    }

    static func isAppKey(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy(isIdentityByte)
    }

    static func isItemID(_ value: String) -> Bool {
        value.hasPrefix("id:") && (4...256).contains(value.utf8.count) && value.utf8.dropFirst(3).allSatisfy(isIdentityByte)
    }

    static func isAccountID(_ value: String) -> Bool {
        value.hasPrefix("dbid:") && (6...256).contains(value.utf8.count) && value.utf8.dropFirst(5).allSatisfy(isIdentityByte)
    }

    static func isToken(_ value: String) -> Bool {
        (1...4096).contains(value.utf8.count) && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    private static func isIdentityByte(_ char: UInt8) -> Bool {
        (48...57).contains(char) || (65...90).contains(char) || (97...122).contains(char) || char == 45 || char == 95
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
        return try JSONDecoder().decode(Credentials.self, from: await send(request))
    }

    private func jsonRequest(path: String, accessToken: String, arguments: [String: String]?) async throws -> Data {
        var request = try authorizedRequest(
            url: URL(string: "https://api.dropboxapi.com/2/" + path)!,
            accessToken: accessToken)
        request.httpMethod = "POST"
        if let arguments {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(arguments)
        }
        return try await send(request)
    }

    private func authorizedRequest(url: URL, accessToken: String) throws -> URLRequest {
        guard !accessToken.isEmpty, accessToken.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw DropboxClientError.invalidAuthorization
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: requestForTransport(request))
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

    private func requestForTransport(_ request: URLRequest) throws -> URLRequest {
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
        if usePhoneFixture {
            guard let original = request.url,
                  var address = URLComponents(url: original, resolvingAgainstBaseURL: false),
                  address.scheme == "https", let host = address.host,
                  ["api.dropboxapi.com", "content.dropboxapi.com"].contains(host) else {
                throw DropboxClientError.invalidConfiguration
            }
            address.host = "127.0.0.1"
            address.port = 18444
            guard let local = address.url else { throw DropboxClientError.invalidConfiguration }
            var redirected = request
            redirected.url = local
            return redirected
        }
        #endif
        return request
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
