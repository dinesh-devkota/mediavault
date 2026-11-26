import Foundation

enum EmbyError: LocalizedError {
    case invalidEndpoint, invalidResponse, invalidCatalog, unsupportedPlayback, unsupportedTranscode, invalidRange, http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Enter the complete HTTPS address for your Emby server."
        case .invalidResponse: return "The Emby server returned an invalid response."
        case .invalidCatalog: return "The Emby catalog changed during the scan. Try again."
        case .unsupportedPlayback: return "Emby did not offer a compatible direct-play source."
        case .unsupportedTranscode: return "Emby did not offer a compatible HLS transcode."
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
            case ImageTags, ProductionYear, RunTimeTicks, CollectionType, ProviderIds
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
        let ProviderIds: [String: String]?
    }

    private struct Page: Decodable {
        let Items: [Item]
        let TotalRecordCount: Int?
    }

    fileprivate struct PlaybackScope: Sendable {
        let owner: UUID
        let accountToken: String
        let accountID: String
        let itemID: String
        let mediaSourceID: String
        let sessionID: String
    }

    struct DirectPlayback: Sendable {
        fileprivate let scope: PlaybackScope
        let container: String
        let textSubtitles: [TextSubtitle]
    }

    struct TranscodedPlayback: Sendable {
        fileprivate let scope: PlaybackScope
        fileprivate let encodingDeviceID: String
        let url: URL
        let textSubtitles: [TextSubtitle]
    }

    struct TextSubtitle: Identifiable, Sendable {
        let id: Int
        let language: String?
        let title: String?
        let forced: Bool
        let hearingImpaired: Bool
    }

    struct ByteRange: Sendable {
        let bytes: Data
        let totalLength: Int64
    }

    enum PlaybackEvent: Equatable, Sendable {
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
        struct MediaStream: Decodable {
            enum CodingKeys: String, CodingKey {
                case type = "Type"
                case Index, IsTextSubtitleStream, IsExternal, Language, DisplayTitle, IsForced, IsHearingImpaired, Codec
            }
            let type: String?
            let Index: Int?
            let IsTextSubtitleStream: Bool?
            let IsExternal: Bool?
            let Language: String?
            let DisplayTitle: String?
            let Codec: String?
            let IsForced: Bool?
            let IsHearingImpaired: Bool?
        }
        struct Source: Decodable {
            let Id: String?
            let Container: String?
            let SupportsDirectPlay: Bool?
            let TranscodingUrl: String?
            let MediaStreams: [MediaStream]?

            var textSubtitles: [TextSubtitle] {
                var seen: Set<Int> = []
                return (MediaStreams ?? []).prefix(128).compactMap { stream in
                    guard stream.type == "Subtitle", stream.IsTextSubtitleStream == true, stream.IsExternal == true,
                          let index = stream.Index, (0...Int(Int32.max)).contains(index), seen.insert(index).inserted else {
                        return nil
                    }
                    return TextSubtitle(id: index, language: stream.Language.map { String($0.prefix(16)) },
                                        title: stream.DisplayTitle.map { String($0.prefix(100)) },
                                        forced: stream.IsForced == true, hearingImpaired: stream.IsHearingImpaired == true)
                }
            }
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
    private static let hlsExtensions: Set<String> = ["m3u8", "ts", "mp4", "m4s", "aac", "vtt"]
    private static let privateHLSParameters: Set<String> = [
        "auth", "key", "password", "secret", "deviceid", "mediasourceid", "playsessionid",
    ]
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
                URLQueryItem(name: "Fields", value: "Overview,ProviderIds"),
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

    func directPlayback(_ account: Account, itemID: String, containers: Set<String>,
                        directVideoCodecs: Set<String>? = nil) async throws -> DirectPlayback {
        let data = try await send(["Items", itemID, "PlaybackInfo"], account: account,
                                  query: [URLQueryItem(name: "UserId", value: account.User.Id)])
        let info = try JSONDecoder().decode(PlaybackInfo.self, from: data)
        guard let sessionID = info.PlaySessionId, Self.headerValue(sessionID) else {
            throw EmbyError.invalidResponse
        }
        for source in info.MediaSources ?? [] where source.SupportsDirectPlay == true {
            if let directVideoCodecs, let codec = source.MediaStreams?.first(where: { $0.type == "Video" })?.Codec,
               !directVideoCodecs.contains(codec.lowercased()) { continue }
            if let sourceID = source.Id, EmbySourceConnection.validID(sourceID),
               let container = source.Container, containers.contains(container.lowercased()) {
                let scope = playbackScope(account, itemID: itemID, mediaSourceID: sourceID, sessionID: sessionID)
                return DirectPlayback(scope: scope, container: container, textSubtitles: source.textSubtitles)
            }
        }
        throw EmbyError.unsupportedPlayback
    }

    func negotiateTranscode(_ account: Account, itemID: String) async throws -> TranscodedPlayback {
        guard EmbySourceConnection.validID(itemID), EmbySourceConnection.validID(account.User.Id) else {
            throw EmbyError.invalidResponse
        }
        // This key belongs to one encoder so cleanup never stops the next video.
        let encodingDeviceID = UUID().uuidString
        let profile: [String: Any] = [
            "UserId": account.User.Id,
            "EnableDirectPlay": false,
            "EnableDirectStream": false,
            "EnableTranscoding": true,
            "DeviceProfile": [
                "Name": "MediaVault Apple TV",
                "MaxStreamingBitrate": 10_000_000,
                "TranscodingProfiles": [[
                    "Container": "ts", "Type": "Video", "Protocol": "hls", "Context": "Streaming",
                    "VideoCodec": "h264", "AudioCodec": "aac", "MaxAudioChannels": "2",
                ]],
            ],
        ]
        let data = try await send(["Items", itemID, "PlaybackInfo"], account: account, query: [
            URLQueryItem(name: "UserId", value: account.User.Id),
            URLQueryItem(name: "DeviceId", value: encodingDeviceID),
        ], body: JSONSerialization.data(withJSONObject: profile))
        let info = try JSONDecoder().decode(PlaybackInfo.self, from: data)
        guard let sessionID = info.PlaySessionId, Self.headerValue(sessionID) else { throw EmbyError.invalidResponse }
        for source in info.MediaSources ?? [] {
            guard let sourceID = source.Id, EmbySourceConnection.validID(sourceID),
                  let reference = source.TranscodingUrl, !reference.isEmpty else { continue }
            let scope = playbackScope(account, itemID: itemID, mediaSourceID: sourceID, sessionID: sessionID)
            let url = try scopedHLSResource(reference, relativeTo: endpoint, scope: scope, encodingDeviceID: encodingDeviceID)
            guard url.pathExtension.lowercased() == "m3u8" else { throw EmbyError.unsupportedTranscode }
            return TranscodedPlayback(scope: scope, encodingDeviceID: encodingDeviceID, url: url, textSubtitles: source.textSubtitles)
        }
        throw EmbyError.unsupportedTranscode
    }

    func hlsResource(_ reference: String, relativeTo base: URL, account: Account, playback: TranscodedPlayback) throws -> URL {
        guard owns(playback.scope, account: account) else { throw EmbyError.invalidResponse }
        return try scopedHLSResource(reference, relativeTo: base, scope: playback.scope, encodingDeviceID: playback.encodingDeviceID)
    }

    func readHLS(_ resource: URL, account: Account, playback: TranscodedPlayback,
                 range: String?) async throws -> (data: Data, contentRange: String?) {
        let url = try hlsResource(resource.absoluteString, relativeTo: playback.url, account: account, playback: playback)
        let isPlaylist = url.pathExtension.lowercased() == "m3u8"
        let limit = isPlaylist ? 2 * 1024 * 1024 : 16 * 1024 * 1024
        let requestedRange = try range.map { value -> (start: Int64, end: Int64?) in
            guard value.range(of: #"^bytes=[0-9]{1,19}-[0-9]{0,19}$"#, options: .regularExpression) != nil else {
                throw EmbyError.invalidRange
            }
            let bounds = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let start = Int64(bounds[0]) else { throw EmbyError.invalidRange }
            if bounds[1].isEmpty { return (start, nil) }
            guard let end = Int64(bounds[1]), end >= start, end - start < Int64(limit) else {
                throw EmbyError.invalidRange
            }
            return (start, end)
        }

        var request = try authorizedRequest(url, account: account)
        request.setValue(isPlaylist ? "application/vnd.apple.mpegurl" : "*/*", forHTTPHeaderField: "Accept")
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        guard http.statusCode == 200 || http.statusCode == 206 else { throw EmbyError.http(http.statusCode) }
        guard response.expectedContentLength <= Int64(limit),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            throw EmbyError.invalidResponse
        }
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        let expectedLength: Int64
        if http.statusCode == 206 {
            guard let requestedRange, let contentRange, let span = WebDAVTransport.parseRange(contentRange),
                  span.start == requestedRange.start, span.end - span.start < Int64(limit),
                  span.end == min(requestedRange.end ?? span.total - 1, span.total - 1),
                  response.expectedContentLength < 0 || response.expectedContentLength == span.end - span.start + 1 else {
                throw EmbyError.invalidRange
            }
            expectedLength = span.end - span.start + 1
        } else {
            guard contentRange == nil else { throw EmbyError.invalidRange }
            expectedLength = response.expectedContentLength
        }

        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw EmbyError.invalidRange }
            data.append(byte)
        }
        guard !data.isEmpty, expectedLength < 0 || expectedLength == Int64(data.count) else { throw EmbyError.invalidRange }
        if contentRange == nil, let requestedRange {
            // Some Emby resources only serve the full segment, which is bounded above.
            let size = Int64(data.count)
            guard requestedRange.start < size else { throw EmbyError.http(416) }
            let end = min(requestedRange.end ?? size - 1, size - 1)
            return (data.subdata(in: Int(requestedRange.start)..<Int(end + 1)), "bytes \(requestedRange.start)-\(end)/\(size)")
        }
        return (data, contentRange)
    }

    func stopTranscode(_ account: Account, playback: TranscodedPlayback) async throws {
        guard owns(playback.scope, account: account) else { throw EmbyError.invalidResponse }
        var request = try makeRequest(["Videos", "ActiveEncodings"], account: account, query: [
            URLQueryItem(name: "DeviceId", value: playback.encodingDeviceID),
            URLQueryItem(name: "PlaySessionId", value: playback.scope.sessionID),
        ])
        request.httpMethod = "DELETE"
        _ = try await send(request, maximumBytes: Self.maximumBody)
    }

    private func scopedHLSResource(_ reference: String, relativeTo parent: URL, scope: PlaybackScope,
                                   encodingDeviceID: String) throws -> URL {
        guard (1...8_192).contains(reference.utf8.count), !reference.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let origin = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let url = URL(string: reference, relativeTo: parent)?.absoluteURL,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host?.lowercased() == origin.host?.lowercased(),
              (parts.port ?? 443) == (origin.port ?? 443),
              parts.user == nil, parts.password == nil, parts.fragment == nil else { throw EmbyError.invalidResponse }

        let prefix = try Self.hlsPathComponents(origin.percentEncodedPath)
        let path = try Self.hlsPathComponents(parts.percentEncodedPath)
        var media = path
        if !prefix.isEmpty, path.starts(with: prefix) {
            media.removeFirst(prefix.count)
        } else if path.first?.lowercased() == "emby" {
            media.removeFirst()
        }
        guard media.count >= 3, media[0].lowercased() == "videos", media[1] == scope.itemID,
              media.allSatisfy(Self.headerValue), Self.hlsExtensions.contains(url.pathExtension.lowercased()),
              !(prefix + path + [scope.mediaSourceID, scope.sessionID]).contains(where: { Self.containsToken($0, token: scope.accountToken) })
        else { throw EmbyError.invalidResponse }

        let target = media.reduce(endpoint) { $0.appendingPathComponent($1, isDirectory: false) }
        guard var result = URLComponents(url: target, resolvingAgainstBaseURL: false) else { throw EmbyError.invalidResponse }
        result.queryItems = (parts.queryItems ?? []).filter { parameter in
            let normalized = Self.decodedHLSValue(parameter.name).lowercased().filter { $0.isLetter || $0.isNumber }
            return !Self.privateHLSParameters.contains(normalized)
                && !["token", "apikey", "authorization"].contains(where: { normalized.contains($0) })
                && !Self.containsToken(parameter.name, token: scope.accountToken)
                && parameter.value.map { !Self.containsToken($0, token: scope.accountToken) } != false
        } + [
            URLQueryItem(name: "DeviceId", value: encodingDeviceID),
            URLQueryItem(name: "MediaSourceId", value: scope.mediaSourceID),
            URLQueryItem(name: "PlaySessionId", value: scope.sessionID),
        ]
        result.percentEncodedQuery = result.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let resultURL = result.url else { throw EmbyError.invalidResponse }
        return resultURL
    }

    private static func hlsPathComponents(_ path: String) throws -> [String] {
        try path.split(separator: "/").map { component in
            guard let decoded = String(component).removingPercentEncoding, decoded != ".", decoded != "..",
                  !decoded.contains("/") && !decoded.contains("\\") else { throw EmbyError.invalidResponse }
            return decoded
        }
    }

    private static func containsToken(_ string: String, token: String) -> Bool {
        decodedHLSValue(string).contains(token)
    }

    private static func decodedHLSValue(_ string: String) -> String {
        var value = string
        while let decoded = value.removingPercentEncoding, decoded != value { value = decoded }
        return value
    }

    func read(_ account: Account, playback: DirectPlayback, offset: Int64, length: Int) async throws -> ByteRange {
        let scope = playback.scope
        guard owns(scope, account: account), offset >= 0, (1...Self.maximumBody).contains(length),
              offset <= Int64.max - Int64(length) else { throw EmbyError.invalidRange }
        let end = offset + Int64(length) - 1
        var request = try makeRequest(["Videos", scope.itemID, "stream"], account: account, query: [
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: scope.mediaSourceID),
            URLQueryItem(name: "PlaySessionId", value: scope.sessionID),
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

    func primaryImage(_ account: Account, itemID: String, width: Int) async throws -> Data {
        guard EmbySourceConnection.validID(itemID), (64...1920).contains(width) else { throw EmbyError.invalidResponse }
        return try await send(["Items", itemID, "Images", "Primary"], account: account, query: [
            URLQueryItem(name: "MaxWidth", value: String(width)),
            URLQueryItem(name: "MaxHeight", value: String(width * 2)),
            URLQueryItem(name: "Format", value: "Jpg"),
        ], maximumBytes: 5 * 1024 * 1024, mimeType: "image/jpeg")
    }

    func textSubtitle(_ account: Account, playback: DirectPlayback, index: Int, maximumBytes: Int) async throws -> Data {
        try await textSubtitle(account, scope: playback.scope, tracks: playback.textSubtitles, index: index, maximumBytes: maximumBytes)
    }

    func textSubtitle(_ account: Account, playback: TranscodedPlayback, index: Int, maximumBytes: Int) async throws -> Data {
        try await textSubtitle(account, scope: playback.scope, tracks: playback.textSubtitles, index: index, maximumBytes: maximumBytes)
    }

    private func textSubtitle(_ account: Account, scope: PlaybackScope, tracks: [TextSubtitle],
                              index: Int, maximumBytes: Int) async throws -> Data {
        guard owns(scope, account: account), tracks.contains(where: { $0.id == index }),
              (1...Self.maximumBody).contains(maximumBytes) else { throw EmbyError.invalidResponse }
        return try await send(["Videos", scope.itemID, scope.mediaSourceID, "Subtitles", String(index), "Stream.srt"],
                              account: account, maximumBytes: maximumBytes)
    }

    func report(_ account: Account, playback: DirectPlayback, event: PlaybackEvent, positionMillis: Int64,
                paused: Bool = false) async throws {
        try await report(account, scope: playback.scope, method: "DirectPlay", event: event, positionMillis: positionMillis, paused: paused)
    }

    func report(_ account: Account, playback: TranscodedPlayback, event: PlaybackEvent, positionMillis: Int64,
                paused: Bool = false) async throws {
        try await report(account, scope: playback.scope, method: "Transcode", event: event, positionMillis: positionMillis, paused: paused)
    }

    private func report(_ account: Account, scope: PlaybackScope, method: String, event: PlaybackEvent,
                        positionMillis: Int64, paused: Bool) async throws {
        guard owns(scope, account: account), (0...Int64.max / 10_000).contains(positionMillis) else { throw EmbyError.invalidResponse }
        let body = try JSONEncoder().encode(PlayState(
            ItemId: scope.itemID, MediaSourceId: scope.mediaSourceID, PlaySessionId: scope.sessionID,
            PositionTicks: positionMillis * 10_000, PlayMethod: event == .stopped ? nil : method,
            CanSeek: event == .stopped ? nil : true, IsPaused: event == .stopped ? nil : paused
        ))
        _ = try await send(event.path, account: account, body: body)
    }

    private func playbackScope(_ account: Account, itemID: String, mediaSourceID: String, sessionID: String) -> PlaybackScope {
        PlaybackScope(owner: playbackOwner, accountToken: account.AccessToken, accountID: account.User.Id,
                      itemID: itemID, mediaSourceID: mediaSourceID, sessionID: sessionID)
    }

    private func owns(_ scope: PlaybackScope, account: Account) -> Bool {
        scope.owner == playbackOwner && scope.accountToken == account.AccessToken && scope.accountID == account.User.Id
    }

    private func makeRequest(_ path: [String], account: Account? = nil, query: [URLQueryItem] = [],
                      body: Data? = nil) throws -> URLRequest {
        guard path.allSatisfy({ $0 == "Stream.srt" || EmbySourceConnection.validID($0) }) else { throw EmbyError.invalidResponse }
        let url = path.reduce(endpoint) { $0.appendingPathComponent($1, isDirectory: false) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw EmbyError.invalidEndpoint }
        if !query.isEmpty { components.queryItems = query }
        guard let target = components.url else { throw EmbyError.invalidEndpoint }
        var request = try authorizedRequest(target, account: account)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func authorizedRequest(_ url: URL, account: Account?) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(identity, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let account {
            guard Self.headerValue(account.AccessToken) else { throw EmbyError.invalidResponse }
            request.setValue(account.AccessToken, forHTTPHeaderField: "X-Emby-Token")
        }
        return request
    }

    private func send(_ path: [String], account: Account? = nil, query: [URLQueryItem] = [],
                      body: Data? = nil, maximumBytes: Int = EmbyClient.maximumBody,
                      mimeType: String? = nil) async throws -> Data {
        var request = try makeRequest(path, account: account, query: query, body: body)
        if let mimeType { request.setValue(mimeType, forHTTPHeaderField: "Accept") }
        return try await send(request, maximumBytes: maximumBytes, mimeType: mimeType)
    }

    private func send(_ request: URLRequest, maximumBytes: Int, mimeType: String? = nil) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw EmbyError.http(http.statusCode) }
        guard mimeType == nil || response.mimeType?.lowercased() == mimeType else { throw EmbyError.invalidResponse }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw EmbyError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw EmbyError.invalidResponse }
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
