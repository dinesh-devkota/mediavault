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

    struct CatalogItem: Decodable, Identifiable, Sendable {
        fileprivate struct Variant: Decodable, Sendable {
            struct Part: Decodable, Sendable {
                let key: String
                let size: Int64?
                let container: String?
            }
            let parts: [Part]?
            enum CodingKeys: String, CodingKey { case parts = "Part" }
        }

        let ratingKey: String
        let type: String
        let title: String
        let year: Int?
        let summary: String?
        let grandparentTitle: String?
        let parentIndex: Int?
        let index: Int?
        fileprivate let media: [Variant]?
        var id: String { ratingKey }

        enum CodingKeys: String, CodingKey {
            case ratingKey, type, title, year, summary, grandparentTitle, parentIndex, index
            case media = "Media"
        }
    }

    struct MediaPart: Sendable {
        let size: Int64
        let container: String?
        fileprivate let url: URL
        fileprivate let origin: URL
        fileprivate let serverID: String
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
        enum CodingKeys: String, CodingKey {
            case items = "Metadata"
            case size, totalSize, offset
        }
    }

    typealias Exchange = PlexAccountClient.Exchange
    private let origin: URL
    private let serverID: String
    private let token: String
    private let deviceID: String
    private let exchange: Exchange

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
            return MediaPart(size: size, container: part.container, url: makeURL(path: path),
                             origin: origin, serverID: serverID)
        }
    }

    func read(_ part: MediaPart, offset: Int64, length: Int) async throws -> Data {
        guard part.origin == origin, part.serverID == serverID,
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

    private static func isNumericID(_ value: String) -> Bool {
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
