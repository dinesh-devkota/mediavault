import CineVaultCore
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

struct JellyfinPlayback: Sendable {
    enum Method: String, Sendable { case directPlay = "DirectPlay", transcode = "Transcode" }

    let itemID: String
    let mediaSourceID: String
    let playSessionID: String
    let method: Method
    let url: URL
    let subtitles: [JellyfinSubtitle]
}

struct JellyfinSubtitle: Sendable {
    let index: Int
    let language: String?
    let url: URL
}

struct JellyfinHLSResponse: Sendable {
    let data: Data
    let contentRange: String?
}

enum JellyfinPlaybackEvent: String {
    case started = "Sessions/Playing"
    case progress = "Sessions/Playing/Progress"
    case stopped = "Sessions/Playing/Stopped"
}

enum JellyfinClientError: LocalizedError, Equatable {
    case invalidAddress, invalidIdentity, invalidResponse, invalidCatalog, unplayable, status(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter the full HTTPS address for your Jellyfin server."
        case .invalidIdentity: return "The Jellyfin device or session identity is invalid."
        case .invalidResponse: return "The server returned an invalid Jellyfin response."
        case .invalidCatalog: return "The library changed during import. Try again."
        case .unplayable: return "Jellyfin could not find a format this device can play."
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

    private struct PlaybackInfo: Decodable {
        struct Source: Decodable {
            struct Stream: Decodable {
                let type: String?
                let index: Int?
                let textSubtitle: Bool?
                let language: String?
                enum CodingKeys: String, CodingKey {
                    case type = "Type", index = "Index", textSubtitle = "IsTextSubtitleStream", language = "Language"
                }
            }
            let id: String
            let directPlay: Bool?
            let transcode: String?
            let streams: [Stream]?
            enum CodingKeys: String, CodingKey {
                case id = "Id", directPlay = "SupportsDirectPlay", transcode = "TranscodingUrl", streams = "MediaStreams"
            }
        }
        let session: String?
        let sources: [Source]?
        enum CodingKeys: String, CodingKey { case session = "PlaySessionId", sources = "MediaSources" }
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
    private let deviceID: String
    private let exchange: Exchange

    init(endpoint: String, deviceID: String, version: String, exchange: Exchange? = nil) throws {
        guard let address = try? WebDAVAddress(endpoint) else { throw JellyfinClientError.invalidAddress }
        guard Self.validHeaderValue(deviceID), Self.validHeaderValue(version) else { throw JellyfinClientError.invalidIdentity }
        self.address = address
        self.deviceID = deviceID
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

    func playback(_ account: JellyfinAccount, itemID: String, startMillis: Int64, deviceProfile: Data,
                  allowDirect: Bool = true) async throws -> JellyfinPlayback {
        guard let profile = try JSONSerialization.jsonObject(with: deviceProfile) as? [String: Any] else {
            throw JellyfinClientError.invalidResponse
        }
        let path = try pathFor("Items", itemID, "PlaybackInfo")
        let payload: [String: Any] = [
            "UserId": account.user.id, "StartTimeTicks": try Self.ticks(startMillis),
            "EnableDirectPlay": allowDirect, "EnableDirectStream": allowDirect, "EnableTranscoding": true,
            "DeviceProfile": profile,
        ]
        let info: PlaybackInfo = try await decode(jsonRequest(path, account: account, payload: payload))
        guard let playSessionID = info.session, !playSessionID.isEmpty else { throw JellyfinClientError.unplayable }
        let direct = allowDirect ? info.sources?.first { $0.directPlay == true } : nil
        guard let source = direct ?? info.sources?.first(where: { $0.transcode?.isEmpty == false }) else {
            throw JellyfinClientError.unplayable
        }
        let stream: URL
        if direct != nil {
            stream = try target(pathFor("Videos", itemID, "stream"), query: [
                URLQueryItem(name: "static", value: "true"),
                URLQueryItem(name: "mediaSourceId", value: source.id),
                URLQueryItem(name: "deviceId", value: deviceID),
                URLQueryItem(name: "playSessionId", value: playSessionID),
            ])
        } else {
            stream = try hlsResource(source.transcode ?? "", relativeTo: address.endpoint, itemID: itemID)
            guard stream.pathExtension.lowercased() == "m3u8" else { throw JellyfinClientError.unplayable }
        }
        let subtitles = try (source.streams ?? []).compactMap { entry -> JellyfinSubtitle? in
            guard entry.type == "Subtitle", entry.textSubtitle == true, let index = entry.index, index >= 0 else { return nil }
            let url = try target(pathFor("Videos", itemID, source.id, "Subtitles", String(index), "Stream.vtt"))
            return JellyfinSubtitle(index: index, language: entry.language, url: url)
        }
        return JellyfinPlayback(itemID: itemID, mediaSourceID: source.id, playSessionID: playSessionID,
                                method: direct == nil ? .transcode : .directPlay, url: stream, subtitles: subtitles)
    }

    func report(_ account: JellyfinAccount, playback: JellyfinPlayback, event: JellyfinPlaybackEvent,
                positionMillis: Int64, paused: Bool = false, failed: Bool = false) async throws {
        var payload: [String: Any] = [
            "ItemId": playback.itemID, "MediaSourceId": playback.mediaSourceID, "PlaySessionId": playback.playSessionID,
            "PositionTicks": try Self.ticks(positionMillis),
        ]
        if event == .stopped {
            payload["Failed"] = failed
        } else {
            payload["IsPaused"] = paused
            payload["CanSeek"] = true
            payload["PlayMethod"] = playback.method.rawValue
        }
        _ = try await send(jsonRequest(event.rawValue, account: account, payload: payload))
    }

    func endTranscode(_ account: JellyfinAccount, playback: JellyfinPlayback) async throws {
        guard playback.method == .transcode else { return }
        var request = try request("Videos/ActiveEncodings", account: account, query: [
            URLQueryItem(name: "deviceId", value: deviceID),
            URLQueryItem(name: "playSessionId", value: playback.playSessionID),
        ])
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    func artwork(_ item: JellyfinCatalogItem, width: Int) throws -> URL? {
        guard let tag = item.primaryImage?["Primary"], (1...4096).contains(width) else { return nil }
        return try target(pathFor("Items", item.id, "Images", "Primary"), query: [
            URLQueryItem(name: "tag", value: tag), URLQueryItem(name: "maxWidth", value: String(width)),
        ])
    }

    func readPrimaryImage(itemID: String, tag: String?, maxPixels: Int, account: JellyfinAccount) async throws -> Data {
        let limit = min(4096, max(1, maxPixels))
        var query = [
            URLQueryItem(name: "maxWidth", value: String(limit)),
            URLQueryItem(name: "maxHeight", value: String(limit)),
        ]
        if let tag, !tag.isEmpty { query.append(URLQueryItem(name: "tag", value: tag)) }
        let url = try target(pathFor("Items", itemID, "Images", "Primary"), query: query)
        return try await send(assetRequest(url, account: account))
    }

    func assetRequest(_ url: URL, account: JellyfinAccount) throws -> URLRequest {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.contains(where: { $0.name.lowercased() == "api_key" }) != true,
              let path = scopedPath(parts), !path.isEmpty else { throw JellyfinClientError.invalidAddress }
        var request = URLRequest(url: url)
        request.setValue(try authorization(account), forHTTPHeaderField: "Authorization")
        return request
    }

    func readDirect(_ playback: JellyfinPlayback, account: JellyfinAccount,
                    offset: Int64, length: Int) async throws -> (data: Data, size: Int64) {
        guard playback.method == .directPlay, (1...Self.maxResponse).contains(length),
              offset >= 0, Int64(length) <= Int64.max - offset else { throw JellyfinClientError.unplayable }
        var request = try assetRequest(playback.url, account: account)
        let end = offset + Int64(length) - 1
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await Self.session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw JellyfinClientError.invalidResponse }
        guard http.statusCode == 206 else {
            if http.statusCode == 200 { throw JellyfinClientError.invalidResponse }
            throw JellyfinClientError.status(http.statusCode)
        }
        guard let header = http.value(forHTTPHeaderField: "Content-Range"),
              let range = WebDAVTransport.parseRange(header), range.start == offset, range.end == end,
              response.expectedContentLength < 0 || response.expectedContentLength == Int64(length),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            throw JellyfinClientError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < length else { throw JellyfinClientError.invalidResponse }
            data.append(byte)
        }
        guard data.count == length else { throw JellyfinClientError.invalidResponse }
        return (data, range.total)
    }

    func fetchSubtitle(_ track: JellyfinSubtitle, account: JellyfinAccount) async throws -> SubtitleDocument {
        let request = try assetRequest(track.url, account: account)
        let (bytes, response) = try await Self.session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw JellyfinClientError.invalidResponse }
        guard http.statusCode == 200 else { throw JellyfinClientError.status(http.statusCode) }
        let limit = SubtitleDocument.maximumBytes
        guard response.expectedContentLength <= Int64(limit) else { throw SubtitleError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw SubtitleError.tooLarge }
            data.append(byte)
        }
        return try SubtitleDocument.parse(data)
    }

    func readHLS(_ url: URL, account: JellyfinAccount, range: String?) async throws -> JellyfinHLSResponse {
        var request = try assetRequest(url, account: account)
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await Self.session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw JellyfinClientError.invalidResponse }
        let limit = url.pathExtension.lowercased() == "m3u8" ? 2 * 1024 * 1024 : 16 * 1024 * 1024
        let contentRange: String?
        let requiredLength: Int64
        switch http.statusCode {
        case 200:
            guard range == nil || range == "bytes=0-" else { throw JellyfinClientError.invalidResponse }
            contentRange = nil
            requiredLength = response.expectedContentLength
        case 206:
            guard let range, range.hasPrefix("bytes="), let separator = range.firstIndex(of: "-"),
                  let start = Int64(range.dropFirst("bytes=".count).prefix { $0 != "-" }),
                  let header = http.value(forHTTPHeaderField: "Content-Range"),
                  let span = WebDAVTransport.parseRange(header), span.start == start,
                  span.end - span.start < Int64(limit),
                  let requestedEnd = range[range.index(after: separator)...].isEmpty ? span.total - 1 :
                    Int64(range[range.index(after: separator)...]),
                  span.end == min(requestedEnd, span.total - 1),
                  response.expectedContentLength < 0 || response.expectedContentLength == span.end - span.start + 1 else {
                throw JellyfinClientError.invalidResponse
            }
            contentRange = "bytes \(span.start)-\(span.end)/\(span.total)"
            requiredLength = span.end - span.start + 1
        default: throw JellyfinClientError.status(http.statusCode)
        }
        guard response.expectedContentLength <= Int64(limit),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            throw JellyfinClientError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw JellyfinClientError.invalidResponse }
            data.append(byte)
        }
        guard !data.isEmpty, requiredLength < 0 || requiredLength == Int64(data.count) else {
            throw JellyfinClientError.invalidResponse
        }
        return JellyfinHLSResponse(data: data, contentRange: contentRange)
    }

    private func pathFor(_ parts: String...) throws -> String {
        guard parts.allSatisfy({ !$0.contains("/") && WebDAVAddress.contains($0, within: "") }) else {
            throw JellyfinClientError.invalidResponse
        }
        return parts.joined(separator: "/")
    }

    private func scopedPath(_ parts: URLComponents) -> String? {
        var clean = parts
        clean.query = nil
        guard let url = clean.url else { return nil }
        return address.relativePath(href: url.absoluteString, requested: address.endpoint)
    }

    func hlsResource(_ value: String, relativeTo parent: URL, itemID: String) throws -> URL {
        let rootRelative = value.lowercased().hasPrefix("/videos/")
        let relative = rootRelative ? String(value.dropFirst()) : value
        guard !relative.isEmpty,
              let url = URL(string: relative, relativeTo: rootRelative ? address.endpoint : parent)?.absoluteURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.fragment == nil,
              let path = scopedPath(parts), ["m3u8", "ts", "m4s", "mp4", "aac", "vtt"].contains(url.pathExtension.lowercased())
        else { throw JellyfinClientError.invalidAddress }
        let pathParts = path.split(separator: "/")
        guard pathParts.count >= 2, pathParts[0].lowercased() == "videos", Self.sameItemID(String(pathParts[1]), itemID) else {
            throw JellyfinClientError.invalidAddress
        }
        let parameters = (parts.queryItems ?? []).filter { $0.name.lowercased() != "api_key" }
        parts.queryItems = parameters.isEmpty ? nil : parameters
        guard let scoped = parts.url else { throw JellyfinClientError.invalidAddress }
        return scoped
    }

    private static func sameItemID(_ candidate: String, _ itemID: String) -> Bool {
        if candidate == itemID { return true }
        func compactUUID(_ value: String) -> String? {
            if UUID(uuidString: value) != nil { return value.replacingOccurrences(of: "-", with: "").lowercased() }
            let bytes = value.utf8
            guard bytes.count == 32, bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                return nil
            }
            return value.lowercased()
        }
        guard let candidateID = compactUUID(candidate) else { return false }
        return candidateID == compactUUID(itemID)
    }

    private static func ticks(_ milliseconds: Int64) throws -> Int64 {
        let (ticks, overflow) = milliseconds.multipliedReportingOverflow(by: 10_000)
        guard milliseconds >= 0, !overflow else { throw JellyfinClientError.invalidResponse }
        return ticks
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

    private func target(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        let url = try address.url(for: path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw JellyfinClientError.invalidAddress }
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let target = components.url else { throw JellyfinClientError.invalidAddress }
        return target
    }

    private func authorization(_ account: JellyfinAccount?) throws -> String {
        guard let account else { return deviceHeader }
        _ = try validated(account)
        return deviceHeader + ", Token=\"\(account.token)\""
    }

    private func request(_ path: String, account: JellyfinAccount? = nil, query: [URLQueryItem] = [],
                         body: [String: String]? = nil) throws -> URLRequest {
        var request = URLRequest(url: try target(path, query: query))
        request.setValue(try authorization(account), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { setJSON(try JSONEncoder().encode(body), on: &request) }
        return request
    }

    private func jsonRequest(_ path: String, account: JellyfinAccount, payload: [String: Any]) throws -> URLRequest {
        var request = try request(path, account: account)
        setJSON(try JSONSerialization.data(withJSONObject: payload), on: &request)
        return request
    }

    private func setJSON(_ body: Data, on request: inout URLRequest) {
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
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
