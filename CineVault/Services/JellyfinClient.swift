import Foundation

struct JellyfinUser: Decodable, Sendable {
    let id: String
    let name: String
    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
}

struct JellyfinAccount: Decodable, Sendable {
    let token: String
    let user: JellyfinUser
    enum CodingKeys: String, CodingKey { case token = "AccessToken", user = "User" }
}

struct JellyfinQuickConnect: Decodable, Sendable {
    let code: String
    let secret: String
    let authenticated: Bool
    enum CodingKeys: String, CodingKey { case code = "Code", secret = "Secret", authenticated = "Authenticated" }
}

struct JellyfinCatalogItem: Decodable, Sendable, Identifiable {
    let id: String
    let name: String
    let type: String
    let collection: String?
    let seriesID: String?
    let seasonID: String?
    let seriesName: String?
    let season: Int?
    let number: Int?
    let overview: String?
    let year: Int?
    let rating: String?
    let primaryImage: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", collection = "CollectionType"
        case seriesID = "SeriesId", seasonID = "SeasonId", seriesName = "SeriesName"
        case season = "ParentIndexNumber", number = "IndexNumber", overview = "Overview"
        case year = "ProductionYear", rating = "OfficialRating", primaryImage = "ImageTags"
    }
}

enum JellyfinClientError: LocalizedError, Equatable {
    case invalidAddress, invalidIdentity, invalidResponse, invalidCatalog, status(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter the full HTTPS address for your Jellyfin server."
        case .invalidIdentity: return "The Jellyfin device or session identity is invalid."
        case .invalidResponse: return "The server returned an invalid Jellyfin response."
        case .invalidCatalog: return "The library changed during import. Try again."
        case .status(401): return "Jellyfin rejected this sign-in or the session expired."
        case .status(403): return "This account cannot access the requested Jellyfin content."
        case .status(300..<400): return "Enter the final Jellyfin address. Redirects are blocked to protect your sign-in."
        case .status(let code): return "The Jellyfin request failed (HTTP \(code))."
        }
    }
}

private final class JellyfinRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The server account is independent of MediaVault's local profile and viewing history.
struct JellyfinClient: Sendable {
    typealias Exchange = @Sendable (URLRequest) async throws -> (Data, Int)

    private struct Page: Decodable {
        let items: [JellyfinCatalogItem]
        let start: Int?
        let total: Int?
        enum CodingKeys: String, CodingKey { case items = "Items", start = "StartIndex", total = "TotalRecordCount" }
    }

    private static let pageSize = 100
    private static let maxItems = 250_000
    private static let maxResponse = 8 * 1024 * 1024
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: JellyfinRedirectDelegate(), delegateQueue: nil)
    }()

    private let address: WebDAVAddress
    private let deviceHeader: String
    private let exchange: Exchange

    init(endpoint: String, deviceID: String, version: String, exchange: Exchange? = nil) throws {
        guard let address = try? WebDAVAddress(endpoint) else { throw JellyfinClientError.invalidAddress }
        guard Self.validHeaderValue(deviceID), Self.validHeaderValue(version) else { throw JellyfinClientError.invalidIdentity }
        self.address = address
        deviceHeader = "MediaBrowser Client=\"MediaVault\", Device=\"Apple TV\", DeviceId=\"\(deviceID)\", Version=\"\(version)\""
        self.exchange = exchange ?? { request in try await Self.perform(request) }
    }

    func signIn(username: String, password: String) async throws -> JellyfinAccount {
        let account: JellyfinAccount = try await decode(request("Users/AuthenticateByName", body: ["Username": username, "Pw": password]))
        return try validated(account)
    }

    func beginQuickConnect() async throws -> JellyfinQuickConnect {
        try await decode(request("QuickConnect/Initiate", body: [:]))
    }

    func pollQuickConnect(secret: String) async throws -> JellyfinQuickConnect {
        try await decode(request("QuickConnect/Connect", query: [URLQueryItem(name: "secret", value: secret)]))
    }

    func finishQuickConnect(secret: String) async throws -> JellyfinAccount {
        let account: JellyfinAccount = try await decode(request("Users/AuthenticateWithQuickConnect", body: ["Secret": secret]))
        return try validated(account)
    }

    func signOut(_ account: JellyfinAccount) async throws {
        _ = try await send(request("Sessions/Logout", account: account, body: [:]))
    }

    func libraries(_ account: JellyfinAccount) async throws -> [JellyfinCatalogItem] {
        let page: Page = try await decode(request("UserViews", account: account, query: [
            URLQueryItem(name: "userId", value: account.user.id),
            URLQueryItem(name: "includeExternalContent", value: "false"),
            URLQueryItem(name: "includeHidden", value: "false"),
        ]))
        return page.items
    }

    func catalog(_ account: JellyfinAccount, libraryID: String, onPage: ([JellyfinCatalogItem]) async throws -> Void) async throws {
        var seen: Set<String> = []
        var start = 0
        while true {
            try Task.checkCancellation()
            let parameters = [
                URLQueryItem(name: "userId", value: account.user.id),
                URLQueryItem(name: "parentId", value: libraryID),
                URLQueryItem(name: "recursive", value: "true"),
                URLQueryItem(name: "includeItemTypes", value: "Movie,Series,Season,Episode,Photo,MusicAlbum,Audio"),
                URLQueryItem(name: "fields", value: "Overview"),
                URLQueryItem(name: "enableUserData", value: "false"),
                URLQueryItem(name: "sortBy", value: "SortName"),
                URLQueryItem(name: "startIndex", value: String(start)),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
            ]
            let page: Page = try await decode(request("Items", account: account, query: parameters))
            guard page.items.count <= Self.pageSize, page.start.map({ $0 == start }) ?? true,
                  page.total.map({ $0 >= 0 }) ?? true else { throw JellyfinClientError.invalidCatalog }
            if page.items.isEmpty {
                guard page.total.map({ $0 <= start }) ?? true else { throw JellyfinClientError.invalidCatalog }
                return
            }
            for item in page.items {
                guard !item.id.isEmpty, seen.insert(item.id).inserted else { throw JellyfinClientError.invalidCatalog }
            }
            try await onPage(page.items)
            start += page.items.count
            if page.total.map({ start >= $0 }) ?? (page.items.count < Self.pageSize) { return }
            guard start < Self.maxItems else { throw JellyfinClientError.invalidCatalog }
        }
    }

    private static func validHeaderValue(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45 || byte == 46 || byte == 95
        }
    }

    private func validated(_ account: JellyfinAccount) throws -> JellyfinAccount {
        guard Self.validHeaderValue(account.token), !account.user.id.isEmpty else { throw JellyfinClientError.invalidIdentity }
        return account
    }

    private func request(_ path: String, account: JellyfinAccount? = nil, query: [URLQueryItem] = [],
                         body: [String: String]? = nil) throws -> URLRequest {
        let url = try address.url(for: path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw JellyfinClientError.invalidAddress }
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let target = components.url else { throw JellyfinClientError.invalidAddress }
        var request = URLRequest(url: target)
        var authorization = deviceHeader
        if let account {
            _ = try validated(account)
            authorization += ", Token=\"\(account.token)\""
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func decode<Value: Decodable>(_ request: URLRequest) async throws -> Value {
        let data = try await send(request)
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw JellyfinClientError.invalidResponse }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, status) = try await exchange(request)
        try Task.checkCancellation()
        guard (200..<300).contains(status) else { throw JellyfinClientError.status(status) }
        return data
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw JellyfinClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { return (Data(), http.statusCode) }
        guard response.expectedContentLength <= Int64(maxResponse) else { throw JellyfinClientError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxResponse else { throw JellyfinClientError.invalidResponse }
            data.append(byte)
        }
        return (data, http.statusCode)
    }
}
