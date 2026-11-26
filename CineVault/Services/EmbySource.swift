import Foundation

struct EmbySourceConnection: Sendable {
    let client: EmbyClient
    let account: EmbyClient.Account

    static func client(endpoint: String, sourceID: UUID, session: URLSession? = nil) throws -> EmbyClient {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return try EmbyClient(endpoint: endpoint, deviceID: sourceID.uuidString, appVersion: version, session: session)
    }

    init(config: SourceConfig, session: URLSession? = nil) throws {
        guard config.isEmby, !config.password.isEmpty, Self.validID(config.username) else {
            throw EmbyError.invalidResponse
        }
        client = try Self.client(endpoint: config.host, sourceID: config.id, session: session)
        account = .init(AccessToken: config.password, User: .init(Id: config.username, Name: ""))
    }

    static func validID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func path(_ id: String) -> String { "emby/\(id).mp4" }

    static func photoPath(_ id: String) -> String { "emby-photos/\(id).jpg" }

    static func itemID(for path: String) throws -> String {
        try itemID(for: path, prefix: "emby/", suffix: ".mp4")
    }

    static func photoID(for path: String) throws -> String {
        try itemID(for: path, prefix: "emby-photos/", suffix: ".jpg")
    }

    private static func itemID(for path: String, prefix: String, suffix: String) throws -> String {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { throw EmbyError.invalidCatalog }
        let id = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard validID(id) else { throw EmbyError.invalidCatalog }
        return id
    }

    static func libraries(_ values: [EmbyClient.Item]) -> [EmbyClient.Item] {
        var seen: Set<String> = []
        return values.filter {
            validID($0.Id) && !$0.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                ["movies", "tvshows", "mixed", "homevideos", "photos", ""].contains($0.CollectionType ?? "") &&
                seen.insert($0.Id).inserted
        }
    }

    func directPlayback(path: String) async throws -> EmbyClient.DirectPlayback {
        try await client.directPlayback(account, itemID: Self.itemID(for: path), containers: ["mp4", "m4v", "mov"],
                                        directVideoCodecs: ["h264", "hevc"])
    }
}

struct EmbyCatalogEntry {
    let id: String
    let isPhoto: Bool
    var path: String { isPhoto ? EmbySourceConnection.photoPath(id) : EmbySourceConnection.path(id) }
    let title: String
    let year: Int?
    let overview: String?
    let runtimeMinutes: Int?
    let rating: String?
    let tmdbID: Int?
    let seriesTMDBID: Int?
    let seriesID: String?
    let seriesTitle: String?
    let season: Int?
    let episode: Int?

    static func media(_ items: [EmbyClient.Item]) -> [Self] {
        let series = Dictionary(items.filter { $0.type == "Series" }.map { ($0.Id, $0) },
                                uniquingKeysWith: { first, _ in first })
        return items.compactMap { item in
            guard EmbySourceConnection.validID(item.Id), !item.Name.isEmpty else { return nil }
            let show: EmbyClient.Item?
            if item.type == "Episode" {
                guard let id = item.SeriesId, EmbySourceConnection.validID(id),
                      let name = series[id]?.Name ?? item.SeriesName, !name.isEmpty,
                      let season = item.ParentIndexNumber, (0...999).contains(season),
                      let episode = item.IndexNumber, (0...999).contains(episode) else { return nil }
                show = series[id]
            } else if item.type == "Movie" || item.type == "Photo" { show = nil }
            else { return nil }
            let rating = item.type == "Episode" ? show?.OfficialRating : item.OfficialRating
            let normalized = rating?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let runtime = item.RunTimeTicks.flatMap { $0 >= 0 ? Int(exactly: $0 / 600_000_000) : nil }
            let ids = item.type == "Episode" ? show?.ProviderIds : item.ProviderIds
            let providerID = ids?.first(where: { $0.key.caseInsensitiveCompare("tmdb") == .orderedSame })?.value
            let id = providerID.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
            return Self(id: item.Id, isPhoto: item.type == "Photo", title: item.Name, year: item.ProductionYear,
                        overview: item.Overview, runtimeMinutes: runtime, rating: normalized,
                        tmdbID: item.type == "Movie" ? id : nil, seriesTMDBID: item.type == "Episode" ? id : nil,
                        seriesID: item.type == "Episode" ? item.SeriesId : nil,
                        seriesTitle: item.type == "Episode" ? show?.Name ?? item.SeriesName : nil,
                        season: item.type == "Episode" ? item.ParentIndexNumber : nil,
                        episode: item.type == "Episode" ? item.IndexNumber : nil)
        }
    }
}

/// Serializes heartbeats and the terminal event for the owner's linked Emby account.
actor EmbyPlaybackReporter {
    private typealias Report = @Sendable (EmbyClient.PlaybackEvent, Int64, Bool) async throws -> Void
    private let report: Report?
    private let cleanup: (@Sendable () async -> Void)?
    private var began = false
    private var stopped = false
    private var tail: Task<Void, Never>?

    init(connection: EmbySourceConnection, playback: EmbyClient.DirectPlayback) {
        report = { event, position, paused in
            try await connection.client.report(connection.account, playback: playback, event: event,
                                               positionMillis: position, paused: paused)
        }
        cleanup = nil
    }

    init(connection: EmbySourceConnection, playback: EmbyClient.TranscodedPlayback, reportsProgress: Bool) {
        if reportsProgress {
            report = { event, position, paused in
                try await connection.client.report(connection.account, playback: playback, event: event,
                                                   positionMillis: position, paused: paused)
            }
        } else { report = nil }
        cleanup = { _ = try? await connection.client.stopTranscode(connection.account, playback: playback) }
    }

    func progress(_ seconds: Double, paused: Bool) {
        guard report != nil, !stopped, let position = Self.milliseconds(seconds), began || !paused else { return }
        let event: EmbyClient.PlaybackEvent = began ? .progress : .started
        began = true
        send(event, position, paused: paused)
    }

    func stop(_ seconds: Double) {
        guard !stopped else { return }
        stopped = true
        if began { send(.stopped, Self.milliseconds(seconds) ?? 0, paused: false) }
        if let cleanup {
            let previous = tail
            tail = Task {
                await previous?.value
                await cleanup()
            }
        }
    }

    private func send(_ event: EmbyClient.PlaybackEvent, _ position: Int64, paused: Bool) {
        guard let report else { return }
        let previous = tail
        tail = Task {
            await previous?.value
            try? await report(event, position, paused)
        }
    }

    private static func milliseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, (0...1_000_000_000).contains(seconds) else { return nil }
        return Int64(seconds * 1_000)
    }
}

/// Hold the size contract for one negotiated asset, even when the player seeks.
actor EmbyByteReader {
    let connection: EmbySourceConnection
    let playback: EmbyClient.DirectPlayback
    private var total: Int64?

    init(connection: EmbySourceConnection, playback: EmbyClient.DirectPlayback) {
        self.connection = connection
        self.playback = playback
    }

    func size() async throws -> Int64 {
        if let total { return total }
        let range = try await connection.client.read(connection.account, playback: playback, offset: 0, length: 1)
        try check(range)
        return range.totalLength
    }

    func read(_ offset: Int64, _ length: Int) async throws -> Data {
        let range = try await connection.client.read(connection.account, playback: playback, offset: offset, length: length)
        try check(range)
        return range.bytes
    }

    private func check(_ range: EmbyClient.ByteRange) throws {
        guard total == nil || total == range.totalLength else { throw EmbyError.invalidRange }
        total = range.totalLength
    }
}
