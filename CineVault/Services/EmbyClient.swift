import Foundation

enum EmbyError: LocalizedError {
    case invalidEndpoint, invalidResponse, invalidCatalog, http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Enter the complete HTTPS address for your Emby server."
        case .invalidResponse: return "The Emby server returned an invalid response."
        case .invalidCatalog: return "The Emby catalog changed during the scan. Try again."
        case .http(401): return "Emby rejected the credentials or the session expired."
        case .http(403): return "This Emby account cannot access the requested library."
        case .http(let status): return "The Emby server returned HTTP \(status)."
        }
    }
}

private final class EmbyRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct EmbyClient: Sendable {
    struct Account: Decodable, Sendable {
        struct UserInfo: Decodable, Sendable {
            let Id: String
            let Name: String
        }
        let AccessToken: String
        let User: UserInfo
    }

    struct Item: Decodable, Sendable {
        let Id: String
        let Name: String
        let Type: String
        let SeriesId: String?
        let SeasonId: String?
        let ParentIndexNumber: Int?
        let IndexNumber: Int?
        let Overview: String?
        let OfficialRating: String?
        let ImageTags: [String: String]?
    }

    private struct Page: Decodable {
        let Items: [Item]
        let TotalRecordCount: Int?
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: EmbyRedirectDelegate(), delegateQueue: nil)
    }()
    private static let maximumBody = 8 * 1024 * 1024
    private let endpoint: URL
    private let identity: String

    init(endpoint: String, deviceID: String, appVersion: String) throws {
        guard let components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              let address = components.url, Self.headerValue(deviceID), Self.headerValue(appVersion) else {
            throw EmbyError.invalidEndpoint
        }
        self.endpoint = address
        identity = "Emby Client=\"MediaVault\", Device=\"Apple TV\", DeviceId=\"\(deviceID)\", Version=\"\(appVersion)\""
    }

    func signIn(username: String, password: String) async throws -> Account {
        let body = try JSONEncoder().encode(["Username": username, "Pw": password])
        let data = try await send(["Users", "AuthenticateByName"], body: body)
        let account = try JSONDecoder().decode(Account.self, from: data)
        guard Self.headerValue(account.AccessToken), !account.User.Id.isEmpty else { throw EmbyError.invalidResponse }
        return account
    }

    func libraries(_ account: Account) async throws -> [Item] {
        let data = try await send(["Users", account.User.Id, "Views"], account: account)
        return try JSONDecoder().decode(Page.self, from: data).Items
    }

    func catalog(_ account: Account, libraryID: String, onPage: ([Item]) async throws -> Void) async throws {
        var seen: Set<String> = []
        var offset = 0
        let pageSize = 100
        while offset < 250_000 {
            let data = try await send(["Users", account.User.Id, "Items"], account: account, query: [
                URLQueryItem(name: "ParentId", value: libraryID),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Season,Episode,Audio,Photo"),
                URLQueryItem(name: "Fields", value: "Overview"),
                URLQueryItem(name: "EnableUserData", value: "false"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "StartIndex", value: String(offset)),
                URLQueryItem(name: "Limit", value: String(pageSize)),
            ])
            let page = try JSONDecoder().decode(Page.self, from: data)
            guard page.Items.count <= pageSize,
                  page.Items.allSatisfy({ !$0.Id.isEmpty && seen.insert($0.Id).inserted }) else {
                throw EmbyError.invalidCatalog
            }
            if page.Items.isEmpty {
                guard page.TotalRecordCount.map({ $0 <= offset }) ?? true else { throw EmbyError.invalidCatalog }
                return
            }
            try await onPage(page.Items)
            offset += page.Items.count
            if page.TotalRecordCount.map({ offset >= $0 }) ?? (page.Items.count < pageSize) { return }
        }
        throw EmbyError.invalidCatalog
    }

    func signOut(_ account: Account) async throws {
        _ = try await send(["Sessions", "Logout"], account: account, body: Data())
    }

    private func send(_ path: [String], account: Account? = nil, query: [URLQueryItem] = [],
                      body: Data? = nil) async throws -> Data {
        guard path.allSatisfy(Self.headerValue) else { throw EmbyError.invalidResponse }
        let url = path.reduce(endpoint) { $0.appendingPathComponent($1, isDirectory: false) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw EmbyError.invalidEndpoint }
        if !query.isEmpty { components.queryItems = query }
        guard let target = components.url else { throw EmbyError.invalidEndpoint }
        var request = URLRequest(url: target)
        request.setValue(identity, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let account {
            guard Self.headerValue(account.AccessToken) else { throw EmbyError.invalidResponse }
            request.setValue(account.AccessToken, forHTTPHeaderField: "X-Emby-Token")
        }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await Self.session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw EmbyError.http(http.statusCode) }
        guard response.expectedContentLength <= Int64(Self.maximumBody) else { throw EmbyError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumBody else { throw EmbyError.invalidResponse }
            data.append(byte)
        }
        return data
    }

    private static func headerValue(_ value: String) -> Bool {
        value != "." && value != ".." && (1...256).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}
