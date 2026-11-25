import Foundation

enum EmbyError: LocalizedError {
    case invalidEndpoint, invalidResponse, invalidCatalog, unsupportedPlayback, invalidRange, http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Enter the complete HTTPS address for your Emby server."
        case .invalidResponse: return "The Emby server returned an invalid response."
        case .invalidCatalog: return "The Emby catalog changed during the scan. Try again."
        case .unsupportedPlayback: return "Emby did not offer a compatible direct-play source."
        case .invalidRange: return "Emby did not return the requested byte range."
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
        let type: String

        enum CodingKeys: String, CodingKey {
            case Id, Name, SeriesId, SeriesName, SeasonId, ParentIndexNumber, IndexNumber, Overview, OfficialRating
            case ImageTags, ProductionYear, RunTimeTicks, CollectionType
            case type = "Type"
        }
        let SeriesId: String?
        let SeasonId: String?
        let ParentIndexNumber: Int?
        let IndexNumber: Int?
        let Overview: String?
        let OfficialRating: String?
        let ImageTags: [String: String]?
        let SeriesName: String?
        let ProductionYear: Int?
        let RunTimeTicks: Int64?
        let CollectionType: String?
    }

    private struct Page: Decodable {
        let Items: [Item]
        let TotalRecordCount: Int?
    }

    struct DirectPlayback: Sendable {
        fileprivate let owner: UUID
        fileprivate let accountToken: String
        fileprivate let accountID: String
        fileprivate let itemID: String
        fileprivate let mediaSourceID: String
        fileprivate let sessionID: String
        let container: String
    }

    struct ByteRange: Sendable {
        let bytes: Data
        let totalLength: Int64
    }

    enum PlaybackEvent: Equatable {
        case started, progress, stopped

        fileprivate var path: [String] {
            switch self {
            case .started: return ["Sessions", "Playing"]
            case .progress: return ["Sessions", "Playing", "Progress"]
            case .stopped: return ["Sessions", "Playing", "Stopped"]
            }
        }
    }

    private struct PlaybackInfo: Decodable {
        struct Source: Decodable {
            let Id: String?
            let Container: String?
            let SupportsDirectPlay: Bool?
        }
        let MediaSources: [Source]?
        let PlaySessionId: String?
    }

    private struct PlayState: Encodable {
        let ItemId: String
        let MediaSourceId: String
        let PlaySessionId: String
        let PositionTicks: Int64
        let PlayMethod: String?
        let CanSeek: Bool?
        let IsPaused: Bool?
    }

    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: EmbyRedirectDelegate(), delegateQueue: nil)
    }()
    private static let maximumBody = 8 * 1024 * 1024
    let endpoint: URL
    private let identity: String
    private let deviceID: String
    private let playbackOwner = UUID()
    private let session: URLSession

    init(endpoint: String, deviceID: String, appVersion: String, session: URLSession? = nil) throws {
        guard let components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              let address = components.url, Self.headerValue(deviceID), Self.headerValue(appVersion) else {
            throw EmbyError.invalidEndpoint
        }
        self.endpoint = address
        self.deviceID = deviceID
        self.session = session ?? Self.defaultSession
        identity = "Emby Client=\"MediaVault\", Device=\"Apple TV\", DeviceId=\"\(deviceID)\", Version=\"\(appVersion)\""
    }

    func signIn(username: String, password: String) async throws -> Account {
        let body = try JSONEncoder().encode(["Username": username, "Pw": password])
        let data = try await send(["Users", "AuthenticateByName"], body: body)
        let account = try JSONDecoder().decode(Account.self, from: data)
        guard Self.headerValue(account.AccessToken), EmbySourceConnection.validID(account.User.Id) else { throw EmbyError.invalidResponse }
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
                guard page.TotalRecordCount.map({ $0 == offset }) ?? true else { throw EmbyError.invalidCatalog }
                return
            }
            try await onPage(page.Items)
            offset += page.Items.count
            if let count = page.TotalRecordCount {
                guard count >= offset else { throw EmbyError.invalidCatalog }
                if offset == count { return }
            } else if page.Items.count < pageSize { return }
        }
        throw EmbyError.invalidCatalog
    }

    func signOut(_ account: Account) async throws {
        _ = try await send(["Sessions", "Logout"], account: account, body: Data())
    }

    func directPlayback(_ account: Account, itemID: String, containers: Set<String>) async throws -> DirectPlayback {
        let data = try await send(["Items", itemID, "PlaybackInfo"], account: account,
                                  query: [URLQueryItem(name: "UserId", value: account.User.Id)])
        let info = try JSONDecoder().decode(PlaybackInfo.self, from: data)
        guard let sessionID = info.PlaySessionId, Self.headerValue(sessionID) else {
            throw EmbyError.invalidResponse
        }
        for source in info.MediaSources ?? [] where source.SupportsDirectPlay == true {
            if let sourceID = source.Id, Self.headerValue(sourceID),
               let container = source.Container, containers.contains(container.lowercased()) {
                return DirectPlayback(owner: playbackOwner, accountToken: account.AccessToken,
                                      accountID: account.User.Id, itemID: itemID, mediaSourceID: sourceID,
                                      sessionID: sessionID, container: container)
            }
        }
        throw EmbyError.unsupportedPlayback
    }

    func read(_ account: Account, playback: DirectPlayback, offset: Int64, length: Int) async throws -> ByteRange {
        guard playback.owner == playbackOwner, playback.accountToken == account.AccessToken,
              playback.accountID == account.User.Id, offset >= 0, (1...Self.maximumBody).contains(length),
              offset <= Int64.max - Int64(length) else { throw EmbyError.invalidRange }
        let end = offset + Int64(length) - 1
        var request = try makeRequest(["Videos", playback.itemID, "stream"], account: account, query: [
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: playback.mediaSourceID),
            URLQueryItem(name: "PlaySessionId", value: playback.sessionID),
            URLQueryItem(name: "DeviceId", value: deviceID),
        ])
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw EmbyError.http(http.statusCode) }
        let prefix = "bytes \(offset)-\(end)/"
        guard http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
              range.hasPrefix(prefix), let total = Int64(range.dropFirst(prefix.count)), total > end,
              range == prefix + String(total),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
              response.expectedContentLength < 0 || response.expectedContentLength == Int64(length) else {
            throw EmbyError.invalidRange
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < length else { throw EmbyError.invalidRange }
            data.append(byte)
        }
        guard data.count == length else { throw EmbyError.invalidRange }
        return ByteRange(bytes: data, totalLength: total)
    }

    func report(_ account: Account, playback: DirectPlayback, event: PlaybackEvent, positionMillis: Int64,
                paused: Bool = false) async throws {
        guard playback.owner == playbackOwner, playback.accountToken == account.AccessToken,
              playback.accountID == account.User.Id, (0...Int64.max / 10_000).contains(positionMillis) else {
            throw EmbyError.invalidResponse
        }
        let body = try JSONEncoder().encode(PlayState(
            ItemId: playback.itemID, MediaSourceId: playback.mediaSourceID, PlaySessionId: playback.sessionID,
            PositionTicks: positionMillis * 10_000, PlayMethod: event == .stopped ? nil : "DirectPlay",
            CanSeek: event == .stopped ? nil : true, IsPaused: event == .stopped ? nil : paused
        ))
        _ = try await send(event.path, account: account, body: body)
    }

    private func makeRequest(_ path: [String], account: Account? = nil, query: [URLQueryItem] = [],
                      body: Data? = nil) throws -> URLRequest {
        guard path.allSatisfy(EmbySourceConnection.validID) else { throw EmbyError.invalidResponse }
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
        return request
    }

    private func send(_ path: [String], account: Account? = nil, query: [URLQueryItem] = [],
                      body: Data? = nil) async throws -> Data {
        let request = try makeRequest(path, account: account, query: query, body: body)
        let (bytes, response) = try await session.bytes(for: request)
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
