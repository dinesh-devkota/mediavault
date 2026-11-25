import Foundation

/// A MediaVault source represents one Jellyfin library on one server and account.
struct JellyfinSourceConnection: Sendable {
    let client: JellyfinClient
    let account: JellyfinAccount

    static func client(endpoint: String, sourceID: UUID) throws -> JellyfinClient {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return try JellyfinClient(endpoint: endpoint, deviceID: sourceID.uuidString, version: version)
    }

    init(config: SourceConfig) throws {
        guard config.isJellyfin, !config.password.isEmpty, !config.username.isEmpty else { throw JellyfinClientError.invalidIdentity }
        client = try Self.client(endpoint: config.host, sourceID: config.id)
        account = JellyfinAccount(token: config.password, user: JellyfinUser(id: config.username, name: ""))
    }

    static func videoPath(_ item: JellyfinCatalogItem) -> String? {
        guard (item.type == "Movie" || item.type == "Episode"), validItemID(item.id) else { return nil }
        if item.type == "Episode" {
            guard let seriesID = item.seriesID, validItemID(seriesID),
                  let seriesName = item.seriesName, !seriesName.isEmpty,
                  let season = item.season, (0...999).contains(season),
                  let number = item.number, (0...999).contains(number) else { return nil }
            return "\(seriesID)/\(season)/\(item.id).mp4"
        }
        return "\(item.id).mp4"
    }

    static func itemID(for filePath: String) throws -> String {
        let filename = filePath.split(separator: "/").last.map(String.init) ?? ""
        let suffix = ".mp4"
        guard filename.hasSuffix(suffix) else { throw JellyfinClientError.invalidCatalog }
        let id = String(filename.dropLast(suffix.count))
        guard validItemID(id) else { throw JellyfinClientError.invalidCatalog }
        return id
    }

    static func validItemID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    func directPlayback(path: String) async throws -> JellyfinPlayback {
        let id = try Self.itemID(for: path)
        let profile = Data("""
        {
            "Name": "MediaVault Apple TV",
            "MaxStreamingBitrate": 120000000,
            "DirectPlayProfiles": [
                { "Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3,alac,mp3" }
            ]
        }
        """.utf8)
        let playback = try await client.playback(account, itemID: id, startMillis: 0, deviceProfile: profile)
        guard playback.method == .directPlay else { throw JellyfinClientError.unplayable }
        return playback
    }
}

/// Serialize progress so stop cannot overtake an in-flight start or heartbeat.
actor JellyfinPlaybackReporter {
    private let connection: JellyfinSourceConnection
    private let playback: JellyfinPlayback
    private var reportedStart = false
    private var stopped = false
    private var tail: Task<Void, Never>?

    init(connection: JellyfinSourceConnection, playback: JellyfinPlayback) {
        self.connection = connection
        self.playback = playback
    }

    func progress(seconds: Double) {
        guard !stopped, let position = position(seconds) else { return }
        let event: JellyfinPlaybackEvent = reportedStart ? .progress : .started
        reportedStart = true
        send(event, position: position)
    }

    func stop(seconds: Double) {
        guard !stopped else { return }
        stopped = true
        if reportedStart { send(.stopped, position: position(seconds) ?? 0) }
    }

    private func send(_ event: JellyfinPlaybackEvent, position: Int64) {
        let previous = tail
        let connection = self.connection
        let playback = self.playback
        tail = Task {
            await previous?.value
            try? await connection.client.report(connection.account, playback: playback, event: event, positionMillis: position)
        }
    }

    private func position(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, (0...1_000_000_000).contains(seconds) else { return nil }
        return Int64(seconds * 1_000)
    }
}
