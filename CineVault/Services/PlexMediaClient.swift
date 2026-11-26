import Foundation

/// Reads metadata and media with the selected server's credential. The Plex account credential
/// remains with the account client and never appears in a media URL.
struct PlexMediaClient: Sendable {
    struct Section: Decodable, Identifiable, Sendable {
        let key: String
        let title: String
        let type: String
        var id: String { key }
    }

    struct NumericValue: Decodable, Sendable {
        let value: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) { value = text }
            else { value = try String(container.decode(Int64.self)) }
        }
    }

    struct CatalogItem: Decodable, Identifiable, Sendable {
        fileprivate struct Variant: Decodable, Sendable {
            struct Part: Decodable, Sendable {
                let key: String
                let size: Int64?
                let container: String?
                let streams: [Stream]?
                enum CodingKeys: String, CodingKey { case key, size, container; case streams = "Stream" }
            }
            struct Stream: Decodable, Sendable {
                let id: NumericValue?
                let streamType: Int?
                let key: String?
                let codec: String?
                let languageCode: String?
                let forced: Bool?
                let hearingImpaired: Bool?
            }
            let parts: [Part]?
            let container: String?
            enum CodingKeys: String, CodingKey { case container; case parts = "Part" }
        }

        let ratingKey: String
        let type: String
        let title: String
        let year: Int?
        let summary: String?
        let grandparentTitle: String?
        let grandparentRatingKey: String?
        let contentRating: String?
        let librarySectionID: NumericValue?
        let thumb: String?
        let duration: Int64?
        let parentIndex: Int?
        let index: Int?
        fileprivate let media: [Variant]?
        var id: String { ratingKey }

        enum CodingKeys: String, CodingKey {
            case ratingKey, type, title, year, summary, grandparentTitle, grandparentRatingKey, parentIndex, index
            case contentRating, librarySectionID, thumb, duration
            case media = "Media"
        }
    }

    struct TextSubtitle: Identifiable, Sendable {
        let id: String
        let language: String?
        let forced: Bool
        let hearingImpaired: Bool
        fileprivate let path: [String]
    }

    struct MediaPart: Sendable {
        let size: Int64
        let container: String?
        let textSubtitles: [TextSubtitle]
        fileprivate let url: URL
        fileprivate let binding: UUID
    }

    private struct Response<Payload: Decodable>: Decodable {
        let mediaContainer: Payload
        enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    }

    private struct Sections: Decodable {
        let directory: [Section]?
        enum CodingKeys: String, CodingKey { case directory = "Directory" }
    }

    private struct Page: Decodable {
        let items: [CatalogItem]?
        let size: Int?
        let totalSize: Int?
        let offset: Int?
        let librarySectionID: NumericValue?
        enum CodingKeys: String, CodingKey {
            case items = "Metadata"
            case size, totalSize, offset, librarySectionID
        }
    }

    typealias Exchange = PlexAccountClient.Exchange
    let origin: URL
    private let serverID: String
    private let token: String
    private let deviceID: String
    private let exchange: Exchange
    private let binding = UUID()

    init(server: PlexAccountClient.Server, connection: PlexAccountClient.Server.Connection,
         deviceID: String, exchange: Exchange? = nil) throws {
        guard UUID(uuidString: deviceID) != nil else { throw PlexAccountError.invalidIdentity }
        guard !server.clientIdentifier.isEmpty,
              server.secureConnections.contains(where: { $0.uri == connection.uri }),
              let token = server.accessToken, PlexAccountClient.isValidToken(token) else {
            throw PlexAccountError.invalidResponse
        }
        origin = connection.uri
        self.serverID = server.clientIdentifier
        self.token = token
        self.deviceID = deviceID
        self.exchange = exchange ?? { request, limit, status in
            try await PlexAccountClient.exchange(request, limit: limit, expectedStatus: status)
        }
    }

    private struct Identity: Decodable { let machineIdentifier: String }

    func verifyIdentity() async throws {
        var request = authorizedRequest(url: makeURL(path: ["identity"]))
        request.setValue(nil, forHTTPHeaderField: "X-Plex-Token")
        let (data, _) = try await exchange(request, 64 * 1024, 200)
        if let json = try? JSONDecoder().decode(Response<Identity>.self, from: data) {
            guard json.mediaContainer.machineIdentifier == serverID else { throw PlexAccountError.invalidResponse }
            return
        }
        let parser = XMLParser(data: data)
        let reader = PlexIdentityXML()
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.identifier == serverID else { throw PlexAccountError.invalidResponse }
    }

    func item(id: String, in sectionID: String) async throws -> CatalogItem {
        guard Self.isNumericID(id), Self.isNumericID(sectionID) else { throw PlexAccountError.invalidResponse }
        let (data, _) = try await exchange(request(path: ["library", "metadata", id]), 4 * 1024 * 1024, 200)
        let page = try JSONDecoder().decode(Response<Page>.self, from: data).mediaContainer
        guard let items = page.items, items.count == 1, let item = items.first, item.id == id,
              (item.librarySectionID?.value ?? page.librarySectionID?.value) == sectionID,
              page.librarySectionID.map({ $0.value == sectionID }) ?? true else {
            throw PlexAccountError.invalidResponse
        }
        return item
    }

    func image(for item: CatalogItem) async throws -> Data {
        guard Self.isNumericID(item.id), let thumb = item.thumb else { throw PlexAccountError.invalidResponse }
        let path = thumb.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.count == 6, path[0].isEmpty, path[1] == "library", path[2] == "metadata",
              path[3] == item.id, path[4] == "thumb", Self.isNumericID(path[5]) else { throw PlexAccountError.invalidResponse }
        var request = request(path: Array(path.dropFirst()))
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await exchange(request, 5 * 1024 * 1024, 200)
        guard !data.isEmpty, ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"]
            .contains(response.mimeType?.lowercased() ?? "") else { throw PlexAccountError.invalidResponse }
        return data
    }

    func libraries() async throws -> [Section] {
        let (data, _) = try await exchange(request(path: ["library", "sections"]), 4 * 1024 * 1024, 200)
        let container = try JSONDecoder().decode(Response<Sections>.self, from: data).mediaContainer
        return (container.directory ?? []).filter { Self.isNumericID($0.id) && !$0.title.isEmpty }
    }

    func catalog(in section: Section, onPage: ([CatalogItem]) async throws -> Void) async throws {
        guard Self.isNumericID(section.id) else { throw PlexAccountError.invalidResponse }
        try await catalog(path: ["library", "sections", section.id, "all"], onPage: onPage)
    }

    func children(of item: CatalogItem, onPage: ([CatalogItem]) async throws -> Void) async throws {
        guard Self.isNumericID(item.id) else { throw PlexAccountError.invalidResponse }
        try await catalog(path: ["library", "metadata", item.id, "children"], onPage: onPage)
    }

    private func catalog(path: [String], onPage: ([CatalogItem]) async throws -> Void) async throws {
        let pageSize = 100
        var offset = 0
        var seen: Set<String> = []
        while offset < 250_000 {
            try Task.checkCancellation()
            var request = request(path: path)
            request.setValue(String(offset), forHTTPHeaderField: "X-Plex-Container-Start")
            request.setValue(String(pageSize), forHTTPHeaderField: "X-Plex-Container-Size")
            let (data, _) = try await exchange(request, 8 * 1024 * 1024, 200)
            let page = try JSONDecoder().decode(Response<Page>.self, from: data).mediaContainer
            let items = page.items ?? []
            guard items.count <= pageSize, page.size.map({ $0 == items.count }) ?? true,
                  page.offset.map({ $0 == offset }) ?? true, page.totalSize.map({ $0 >= offset + items.count }) ?? true,
                  items.allSatisfy({ Self.isNumericID($0.id) && seen.insert($0.id).inserted }) else {
                throw PlexAccountError.invalidResponse
            }
            if items.isEmpty {
                guard page.totalSize.map({ $0 == offset }) ?? true else { throw PlexAccountError.invalidResponse }
                return
            }
            try await onPage(items)
            offset += items.count
            if page.totalSize.map({ offset == $0 }) ?? (items.count < pageSize) { return }
        }
        throw PlexAccountError.invalidResponse
    }

    /// Select a single file variant. A stack of multiple files requires separate timeline support.
    func singleFileParts(for item: CatalogItem) -> [MediaPart] {
        (item.media ?? []).compactMap { variant in
            guard let parts = variant.parts, parts.count == 1, let part = parts.first,
                  let size = part.size, size > 0, let path = Self.mediaPath(part.key) else { return nil }
            var seen: Set<String> = []
            let subtitles = (part.streams ?? []).prefix(64).compactMap { stream -> TextSubtitle? in
                guard stream.streamType == 3, ["srt", "vtt"].contains(stream.codec?.lowercased() ?? ""),
                      let id = stream.id?.value, Self.isNumericID(id), stream.key == "/library/streams/\(id)",
                      seen.insert(id).inserted else { return nil }
                return TextSubtitle(id: id, language: stream.languageCode.map { String($0.prefix(16)) },
                                    forced: stream.forced == true, hearingImpaired: stream.hearingImpaired == true,
                                    path: ["library", "streams", id])
            }
            return MediaPart(size: size, container: part.container ?? variant.container ?? URL(fileURLWithPath: part.key).pathExtension,
                             textSubtitles: subtitles, url: makeURL(path: path), binding: binding)
        }
    }

    func readSubtitle(_ track: TextSubtitle, for part: MediaPart) async throws -> Data {
        guard part.binding == binding, part.textSubtitles.contains(where: { $0.id == track.id && $0.path == track.path }) else {
            throw PlexAccountError.invalidResponse
        }
        var request = request(path: track.path)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return try await exchange(request, 2 * 1024 * 1024, 200).0
    }

    func read(_ part: MediaPart, offset: Int64, length: Int) async throws -> Data {
        guard part.binding == binding,
              offset >= 0, (1...8 * 1024 * 1024).contains(length),
              offset < part.size, Int64(length) <= part.size - offset else { throw PlexAccountError.invalidResponse }
        let end = offset + Int64(length) - 1
        var request = authorizedRequest(url: part.url)
        request.setValue(nil, forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await exchange(request, length, 206)
        guard response.statusCode == 206, data.count == length,
              response.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(end)/\(part.size)",
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            throw PlexAccountError.invalidResponse
        }
        return data
    }

    private func makeURL(path: [String]) -> URL {
        path.reduce(origin) { $0.appendingPathComponent($1, isDirectory: false) }
    }

    private func request(path: [String]) -> URLRequest { authorizedRequest(url: makeURL(path: path)) }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MediaVault", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("tvOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(deviceID, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        return request
    }

    static func isNumericID(_ value: String) -> Bool {
        (1...20).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func mediaPath(_ key: String) -> [String]? {
        let segments = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (5...6).contains(segments.count), segments[0].isEmpty,
              segments[1] == "library", segments[2] == "parts", isNumericID(segments[3]),
              segments.dropFirst(4).allSatisfy({ segment in
                  !segment.isEmpty && segment != "." && segment != ".." && segment.utf8.count <= 128 &&
                      segment.utf8.allSatisfy {
                          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                              $0 == 45 || $0 == 46 || $0 == 95
                      }
              }) else { return nil }
        return Array(segments.dropFirst())
    }
}

private final class PlexIdentityXML: NSObject, XMLParserDelegate {
    private var visitedRoot = false
    private(set) var identifier: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard !visitedRoot else { return }
        visitedRoot = true
        if elementName == "MediaContainer" { identifier = attributeDict["machineIdentifier"] }
    }
}
