import AVFoundation
import AVKit
import CineVaultCore
import Observation
import SwiftUI
#if CINEVAULT_COMMERCIAL
import CineVaultCommercial
#endif

/// Streams a NAS file into AVPlayer by answering byte-range requests with SMB reads,
/// so playback starts immediately and seeking works without downloading the file.
final class SMBResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "cinevault-smb"
    private static let chunkSize: Int64 = 2 * 1024 * 1024

    struct Reader: Sendable {
        let size: @Sendable () async throws -> Int64
        let read: @Sendable (Int64, Int) async throws -> Data
    }

    fileprivate let config: SourceConfig
    private let reader: Reader
    private let stillAvailable: (@MainActor () -> Bool)?
    private let contentPath: String
    private let path: String
    private let household: HouseholdStore
    private let householdSession: UUID
    private let queue = DispatchQueue(label: "cinevault.resource-loader")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var sizeTask: Task<Int64, Error>?

    init(config: SourceConfig, path: String, household: HouseholdStore = .shared, reader: Reader? = nil,
         contentPath: String? = nil, stillAvailable: (@MainActor () -> Bool)? = nil) {
        self.household = household; householdSession = household.sessionToken
        self.config = config
        self.path = path
        self.contentPath = contentPath ?? path
        self.stillAvailable = stillAvailable
        self.reader = reader ?? Reader(
            size: { try await SMBService.shared.fileSize(config, path: path) },
            read: { try await SMBService.shared.read(config, path: path, offset: $0, length: $1) }
        )
    }

    deinit {
        sizeTask?.cancel()
    }

    func makeAsset() -> AVURLAsset {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "nas"
        components.path = "/" + path
        let asset = AVURLAsset(url: components.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let sizeTask: Task<Int64, Error>
        if let existing = self.sizeTask {
            sizeTask = existing
        } else {
            sizeTask = Task { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.verifyAccess()
                return try await self.reader.size()
            }
            self.sizeTask = sizeTask
        }
        tasks[key] = Task { [weak self] in
            await self?.handle(loadingRequest, sizeTask: sizeTask)
            self?.queue.async { self?.tasks.removeValue(forKey: key) }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    private func handle(_ request: AVAssetResourceLoadingRequest, sizeTask: Task<Int64, Error>) async {
        do {
            let size = try await sizeTask.value
            try Task.checkCancellation()
            try await verifyAccess()
            if let info = request.contentInformationRequest {
                info.contentType = MediaFile.contentType(path: contentPath)
                info.contentLength = size
                info.isByteRangeAccessSupported = true
            }
            if let dataRequest = request.dataRequest {
                guard dataRequest.requestedOffset >= 0 else {
                    throw SMBError.invalidByteRange
                }
                let offset = dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
                let end: Int64
                if dataRequest.requestsAllDataToEndOfResource {
                    end = size
                } else {
                    guard dataRequest.requestedLength >= 0 else { throw SMBError.invalidByteRange }
                    let (requestedEnd, overflow) = dataRequest.requestedOffset.addingReportingOverflow(Int64(dataRequest.requestedLength))
                    guard !overflow else { throw SMBError.invalidByteRange }
                    end = min(size, requestedEnd)
                }
                try await streamBytes(from: offset, to: end) { data in
                    dataRequest.respond(with: data)
                }
            }
            request.finishLoading()
        } catch is CancellationError {
            // AVPlayer cancelled this range (seek or enough buffered).
        } catch {
            request.finishLoading(with: error)
        }
    }

    fileprivate func verifyAccess() async throws {
        guard household.sessionIsCurrent(householdSession),
              household.allowsPath(sourceID: config.id, path: path, caseSensitive: config.isWebDAV || config.isJellyfin,
                                   entireSourceOnly: config.isEmby) else { throw PlaybackPreparationError.fileUnavailable }
        if let stillAvailable {
            let available = await stillAvailable()
            guard available, household.sessionIsCurrent(householdSession) else { throw PlaybackPreparationError.fileUnavailable }
        }
    }

    func streamBytes(from start: Int64, to end: Int64, respond: (Data) -> Void) async throws {
        try await verifyAccess()
        guard start >= 0, end >= start else { throw SMBError.invalidByteRange }
        var offset = start
        while offset < end {
            try Task.checkCancellation()
            let length = Int(min(Self.chunkSize, end - offset))
            if config.isEmby { try await verifyAccess() }
            let data = try await reader.read(offset, length)
            try Task.checkCancellation()
            try await verifyAccess()
            guard !data.isEmpty else { throw SMBError.unexpectedEndOfFile }
            respond(data)
            offset += Int64(data.count)
        }
    }
}

/// Owns the AVPlayer for one movie and persists resume position / watched state.
enum PlaybackPreparationError: LocalizedError {
    case unsupportedFormat
    case fileUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Apple TV's native player cannot play this file's container or audio/video codecs. Use a supported container with compatible codecs."
        case .fileUnavailable:
            return "This file is missing or ignored by its NAS source. Include it again and rescan before playing."
        }
    }
}

@MainActor
final class PlaybackController: ObservableObject {
    let player: AVPlayer
    @Published private(set) var playbackError: String?
    @Published private(set) var didEndNaturally = false
    let subtitles: PlaybackSubtitles
    #if CINEVAULT_COMMERCIAL
    let commercialSession: CommercialPlaybackSession
    #endif
    private let loader: SMBResourceLoader
    private let asset: AVURLAsset
    let movie: Movie
    private var finishedPlayback = false
    private var stopped = false
    private var jellyfinReporter: JellyfinPlaybackReporter?
    private var embyReporter: EmbyPlaybackReporter?
    private var embyRelay: MediaHLSRelay?
    private var jellyfinRelay: MediaHLSRelay?
    private var playbackStateObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var artworkTask: Task<Void, Never>?
    private var itemObservation: NSKeyValueObservation?
    private var householdObserver: NSObjectProtocol?
    private let household: HouseholdStore
    private let householdSession: UUID

    static func isNativeCandidate(_ movie: Movie) -> Bool {
        MediaFile.isPlayable(path: movie.filePath)
    }

    private static func playbackSource(for movie: Movie, household: HouseholdStore = .shared) throws -> MediaSource? {
        guard isNativeCandidate(movie) else { throw PlaybackPreparationError.unsupportedFormat }
        guard let source = movie.source else { return nil }
        guard household.allows(movie), LibrarySearch.isAvailable(movie), !source.isIgnored(filePath: movie.filePath),
              (source.isWebDAV
                ? WebDAVAddress.contains(movie.filePath, within: source.rootPath)
                : SubtitleFile.safePath(movie.filePath, within: source.rootPath) != nil) else { throw PlaybackPreparationError.fileUnavailable }
        return source
    }

    /// Check the actual asset before creating a player or changing playback history.
    static func prepare(movie: Movie, resume: Bool, services: PlaybackServices,
                        defaults: UserDefaults = .standard,
                        sourceConfig: @escaping (MediaSource) throws -> SourceConfig = { try $0.config() },
                        loadPlayable: (AVURLAsset) async throws -> Bool = { try await $0.load(.isPlayable) },
                        household: HouseholdStore = .shared) async throws -> PlaybackController? {
        let householdSession = household.sessionToken
        guard let source = try playbackSource(for: movie, household: household) else { return nil }
        let config = try sourceConfig(source)
        let path = movie.filePath
        if config.isEmby {
            return try await prepareEmby(movie: movie, resume: resume, services: services, defaults: defaults,
                                         household: household, householdSession: householdSession, source: source,
                                         config: config, path: path, sourceConfig: sourceConfig, loadPlayable: loadPlayable)
        }
        if config.isJellyfin {
            return try await prepareJellyfin(
                movie: movie, resume: resume, services: services, defaults: defaults, household: household,
                householdSession: householdSession, source: source, config: config, path: path,
                sourceConfig: sourceConfig, loadPlayable: loadPlayable
            )
        }
        let loader = SMBResourceLoader(config: config, path: path, household: household)
        let asset = loader.makeAsset()
        return try await withTaskCancellationHandler {
            do {
                let playable = try await loadPlayable(asset)
                try Task.checkCancellation()
                guard household.sessionIsCurrent(householdSession) else { throw PlaybackPreparationError.fileUnavailable }
                guard playable else { throw PlaybackPreparationError.unsupportedFormat }
                guard let currentSource = try playbackSource(for: movie, household: household), currentSource === source,
                      movie.filePath == path, try sourceConfig(currentSource) == config else {
                    throw PlaybackPreparationError.fileUnavailable
                }
                return PlaybackController(movie: movie, resume: resume, services: services, defaults: defaults, loader: loader, asset: asset, household: household)
            } catch {
                asset.cancelLoading()
                throw error
            }
        } onCancel: {
            asset.cancelLoading()
        }
    }

    private static func prepareEmby(
        movie: Movie, resume: Bool, services: PlaybackServices, defaults: UserDefaults, household: HouseholdStore,
        householdSession: UUID, source: MediaSource, config: SourceConfig, path: String,
        sourceConfig: @escaping (MediaSource) throws -> SourceConfig, loadPlayable: (AVURLAsset) async throws -> Bool
    ) async throws -> PlaybackController {
        let connection = try EmbySourceConnection(config: config)
        let stillAvailable: @MainActor @Sendable () -> Bool = { [weak movie, weak source] in
            guard let movie, let source, !source.isDeleted, !movie.isDeleted,
                  movie.source === source, movie.filePath == path, household.sessionIsCurrent(householdSession) else { return false }
            return household.allows(movie) && LibrarySearch.isAvailable(movie) && (try? sourceConfig(source)) == config
        }

        func verifySource() throws {
            try Task.checkCancellation()
            guard stillAvailable() else { throw PlaybackPreparationError.fileUnavailable }
        }

        func makeController(asset: AVURLAsset, loader: SMBResourceLoader) async throws -> PlaybackController {
            do {
                let playable = try await withTaskCancellationHandler {
                    try await loadPlayable(asset)
                } onCancel: { asset.cancelLoading() }
                try verifySource()
                guard playable else { throw PlaybackPreparationError.unsupportedFormat }
                return PlaybackController(movie: movie, resume: resume, services: services, defaults: defaults,
                                          loader: loader, asset: asset, household: household)
            } catch {
                asset.cancelLoading()
                throw error
            }
        }

        do {
            let direct = try await connection.directPlayback(path: path)
            try verifySource()
            let reader = EmbyByteReader(connection: connection, playback: direct)
            let loader = SMBResourceLoader(config: config, path: path, household: household,
                                           reader: .init(size: { try await reader.size() }, read: { try await reader.read($0, $1) }),
                                           contentPath: "video.\(direct.container.lowercased())", stillAvailable: stillAvailable)
            let controller = try await makeController(asset: loader.makeAsset(), loader: loader)
            if household.isAdmin {
                controller.attachEmbyReporter(EmbyPlaybackReporter(connection: connection, playback: direct))
            }
            controller.subtitles.providerTracks = embyTracks(direct.textSubtitles, loader: loader) { index in
                try await connection.client.textSubtitle(connection.account, playback: direct,
                                                          index: index, maximumBytes: SubtitleDocument.maximumBytes)
            }
            return controller
        } catch EmbyError.unsupportedPlayback {
            try verifySource()
        } catch PlaybackPreparationError.unsupportedFormat {
            try verifySource()
        } catch {
            try verifySource()
            // AVFoundation may report a codec or container mismatch before isPlayable returns.
            guard (error as NSError).domain == AVFoundationErrorDomain else { throw error }
        }

        let playback = try await connection.client.negotiateTranscode(connection.account,
                                                                       itemID: EmbySourceConnection.itemID(for: path))
        let reporter = EmbyPlaybackReporter(connection: connection, playback: playback, reportsProgress: household.isAdmin)
        var relay: MediaHLSRelay?
        do {
            try verifySource()
            let stream = try MediaHLSRelay(transport: .init(
                entry: playback.url,
                resolve: { reference, parent in
                    try connection.client.hlsResource(reference, relativeTo: parent, account: connection.account, playback: playback)
                },
                read: { url, range in
                    guard await stillAvailable() else { throw PlaybackPreparationError.fileUnavailable }
                    let response: (data: Data, contentRange: String?)
                    do {
                        response = try await connection.client.readHLS(url, account: connection.account,
                                                                       playback: playback, range: range)
                    } catch EmbyError.http(416) {
                        throw MediaHLSRelay.RelayError.invalidRange
                    } catch EmbyError.invalidRange {
                        throw MediaHLSRelay.RelayError.invalidRange
                    }
                    try Task.checkCancellation()
                    guard await stillAvailable() else { throw PlaybackPreparationError.fileUnavailable }
                    return .init(data: response.data, contentRange: response.contentRange)
                }), allowsRead: {
                    household.sessionIsCurrent(householdSession) &&
                        household.allowsPath(sourceID: config.id, path: path, entireSourceOnly: true)
                })
            relay = stream
            let url = try await stream.start()
            try verifySource()
            let loader = SMBResourceLoader(config: config, path: path, household: household, stillAvailable: stillAvailable)
            let controller = try await makeController(asset: AVURLAsset(url: url), loader: loader)
            controller.embyRelay = stream
            controller.attachEmbyReporter(reporter)
            controller.subtitles.providerTracks = embyTracks(playback.textSubtitles, loader: loader) { index in
                try await connection.client.textSubtitle(connection.account, playback: playback,
                                                          index: index, maximumBytes: SubtitleDocument.maximumBytes)
            }
            return controller
        } catch {
            relay?.stop()
            await reporter.stop(0)
            throw error
        }
    }

    private static func embyTracks(
        _ tracks: [EmbyClient.TextSubtitle], loader: SMBResourceLoader, read: @escaping (Int) async throws -> Data
    ) -> PlaybackSubtitles.ProviderTracks {
        let indices = Dictionary(uniqueKeysWithValues: tracks.map { ("emby-caption-\($0.id)", $0.id) })
        let choices = tracks.map {
            SubtitleFile(path: "emby-caption-\($0.id)", language: $0.language, forced: $0.forced,
                         hearingImpaired: $0.hearingImpaired)
        }
        return .init(files: choices, read: { [weak loader] file in
            guard let loader, let index = indices[file.path] else { throw PlaybackPreparationError.fileUnavailable }
            try await loader.verifyAccess()
            let data = try await read(index)
            try Task.checkCancellation()
            try await loader.verifyAccess()
            return try SubtitleDocument.parse(data)
        })
    }

    private static func prepareJellyfin(
        movie: Movie, resume: Bool, services: PlaybackServices, defaults: UserDefaults, household: HouseholdStore,
        householdSession: UUID, source: MediaSource, config: SourceConfig, path: String,
        sourceConfig: (MediaSource) throws -> SourceConfig, loadPlayable: (AVURLAsset) async throws -> Bool
    ) async throws -> PlaybackController {
        let connection = try JellyfinSourceConnection(config: config)
        let sourceID = config.id
        let allowsRead: @Sendable () -> Bool = {
            household.sessionIsCurrent(householdSession) && household.allowsPath(sourceID: sourceID, path: path, caseSensitive: true)
        }
        func verifySource() throws {
            try Task.checkCancellation()
            guard allowsRead(), let currentSource = try playbackSource(for: movie, household: household),
                  currentSource === source, movie.filePath == path, try sourceConfig(currentSource) == config else {
                throw PlaybackPreparationError.fileUnavailable
            }
        }

        for allowDirect in [true, false] {
            let stream = try await connection.playback(path: path, allowDirect: allowDirect)
            let reporter = JellyfinPlaybackReporter(connection: connection, playback: stream)
            var relay: MediaHLSRelay?
            var loadingAsset: AVURLAsset?
            do {
                try verifySource()
                let loader: SMBResourceLoader
                let asset: AVURLAsset
                switch stream.method {
                case .directPlay:
                    let reader = SMBResourceLoader.Reader(
                        size: { try await connection.client.readDirect(stream, account: connection.account, offset: 0, length: 1).size },
                        read: { try await connection.client.readDirect(stream, account: connection.account, offset: $0, length: $1).data }
                    )
                    loader = SMBResourceLoader(config: config, path: path, household: household, reader: reader)
                    asset = loader.makeAsset()
                case .transcode:
                    let streamRelay = try MediaHLSRelay(connection: connection, playback: stream, allowsRead: allowsRead)
                    relay = streamRelay
                    let url = try await streamRelay.start()
                    loader = SMBResourceLoader(config: config, path: path, household: household)
                    asset = AVURLAsset(url: url)
                }
                loadingAsset = asset
                let playable = try await withTaskCancellationHandler {
                    try await loadPlayable(asset)
                } onCancel: { asset.cancelLoading() }
                try verifySource()
                guard playable else { throw PlaybackPreparationError.unsupportedFormat }

                let controller = PlaybackController(movie: movie, resume: resume, services: services, defaults: defaults,
                                                    loader: loader, asset: asset, household: household)
                controller.jellyfinRelay = relay
                controller.attachJellyfinReporter(reporter)
                controller.subtitles.providerTracks = jellyfinTracks(stream, connection: connection)
                return controller
            } catch {
                loadingAsset?.cancelLoading()
                relay?.stop()
                await reporter.stop(seconds: 0)
                try verifySource()
                guard allowDirect, stream.method == .directPlay else { throw error }
            }
        }
        throw JellyfinClientError.unplayable
    }

    private static func jellyfinTracks(_ stream: JellyfinPlayback, connection: JellyfinSourceConnection) -> PlaybackSubtitles.ProviderTracks {
        let tracks = Dictionary(stream.subtitles.prefix(64).map { ("jellyfin-caption-\($0.index)", $0) },
                                uniquingKeysWith: { first, _ in first })
        let choices = tracks.keys.sorted {
            (tracks[$0]?.index ?? 0) < (tracks[$1]?.index ?? 0)
        }.map { id in SubtitleFile(path: id, language: tracks[id]?.language) }
        return PlaybackSubtitles.ProviderTracks(files: choices, read: { file in
            guard let track = tracks[file.path] else { throw JellyfinClientError.invalidResponse }
            return try await connection.client.fetchSubtitle(track, account: connection.account)
        })
    }

    convenience init?(movie: Movie, resume: Bool, services: PlaybackServices,
          defaults: UserDefaults = .standard,
          sourceConfig: (MediaSource) throws -> SourceConfig = { try $0.config() }, household: HouseholdStore = .shared) throws {
        guard let source = try Self.playbackSource(for: movie, household: household) else { return nil }
        guard !source.isJellyfin, !source.isEmby else { throw PlaybackPreparationError.fileUnavailable }
        let loader = SMBResourceLoader(config: try sourceConfig(source), path: movie.filePath, household: household)
        self.init(movie: movie, resume: resume, services: services, defaults: defaults, loader: loader, asset: loader.makeAsset(), household: household)
    }

    private init(movie: Movie, resume: Bool, services: PlaybackServices, defaults: UserDefaults, loader: SMBResourceLoader, asset: AVURLAsset, household: HouseholdStore) {
        self.household = household; householdSession = household.sessionToken
        self.movie = movie
        self.loader = loader
        self.asset = asset
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = Self.metadata(for: movie)
        let player = AVPlayer(playerItem: item)
        self.player = player
        subtitles = PlaybackSubtitles(player: player, movie: movie, config: loader.config, defaults: defaults)
        #if CINEVAULT_COMMERCIAL
        commercialSession = services.commercial.makePlaybackSession(
            player: player, mediaID: household.playbackID(movie.id), resume: resume,
            initialPosition: resume ? services.resumePosition(movie, household: household) : 0
        )
        #else
        let position = services.resumePosition(movie, household: household)
        if resume, position > 0 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        }
        #endif
        householdObserver = NotificationCenter.default.addObserver(forName: HouseholdStore.willLock, object: household, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        observeAccess()
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "The native player could not decode this file."
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.playbackError = "Playback could not continue. Check the NAS connection and the file's codecs. \(message)"
                self.didEndNaturally = false
                self.player.pause()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.record(time: time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, self.playbackError == nil else { return }
                if self.player.currentItem?.forwardPlaybackEndTime.isValid == true {
                    self.record(time: self.player.currentTime().seconds)
                } else {
                    self.finish()
                    self.didEndNaturally = true
                }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.didEndNaturally = false
                self.playbackError = "Playback could not continue. Check the NAS connection and try again."
                self.player.pause()
            }
        }
        if let url = TMDB.imageURL(movie.posterPath, size: "w342") {
            artworkTask = Task { [weak self, weak item] in
                do {
                    let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
                    try Task.checkCancellation()
                    guard let self, !self.stopped, let item, self.player.currentItem === item,
                          let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                          data.count <= 5 * 1024 * 1024, UIImage(data: data) != nil else { return }
                    let artwork = AVMutableMetadataItem()
                    artwork.identifier = .commonIdentifierArtwork
                    artwork.value = data as NSData
                    item.externalMetadata = Self.metadata(for: self.movie) + [artwork]
                } catch {
                    // Artwork is optional; the title and playback remain available offline.
                }
            }
        }
    }

    static func metadata(for movie: Movie) -> [AVMetadataItem] {
        guard HouseholdStore.shared.allows(movie) else { return [] }
        func item(_ id: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
            guard let value, !value.isEmpty else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item
        }
        let episode = movie.episodeInfo.map {
            "\(movie.seriesTitle ?? $0.seriesTitle) · Season \(movie.seasonNumber ?? $0.season) · Episode \(movie.episodeNumber ?? $0.episode)"
        }
        let facts = [episode, movie.year.map(String.init), movie.genres.isEmpty ? nil : movie.genres.joined(separator: " · "),
                     movie.runtimeMinutes.map { "\($0) min" }].compactMap { $0 }.joined(separator: " · ")
        return [item(.commonIdentifierTitle, movie.title.isEmpty ? movie.fileName : movie.title),
                item(.iTunesMetadataTrackSubTitle, facts),
                item(.commonIdentifierDescription, movie.overview)].compactMap { $0 }
    }

    func record(time: Double) {
        guard !stopped, validateAccess(), !finishedPlayback, time.isFinite, time > 0 else { return }
        let boundary = player.currentItem?.forwardPlaybackEndTime
        let limit = boundary.flatMap { $0.isValid && $0.seconds.isFinite ? $0.seconds : nil }
        let position = limit.map { min(time, $0) } ?? time
        guard position > 0 else { return }
        if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            movie.duration = duration
            if position / duration > 0.92 {
                finish()
                return
            }
        }
        movie.recordHouseholdProgress(watched: false, position: position, at: Date(), household: household, session: householdSession)
        if let embyReporter, household.sessionIsCurrent(householdSession) {
            let paused = player.rate == 0
            Task { await embyReporter.progress(position, paused: paused) }
        }
        if let jellyfinReporter, player.rate > 0, household.sessionIsCurrent(householdSession) {
            Task { await jellyfinReporter.progress(seconds: position) }
        }
    }

    private func attachEmbyReporter(_ reporter: EmbyPlaybackReporter) {
        embyReporter = reporter
        playbackStateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.validateAccess() else { return }
                let state = self.player.timeControlStatus
                if state == .playing || state == .paused {
                    await reporter.progress(self.player.currentTime().seconds, paused: state == .paused)
                }
            }
        }
    }

    private func attachJellyfinReporter(_ reporter: JellyfinPlaybackReporter) {
        jellyfinReporter = reporter
        playbackStateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.validateAccess() else { return }
                let state = self.player.timeControlStatus
                if state == .playing || state == .paused {
                    await reporter.progress(seconds: self.player.currentTime().seconds, paused: state == .paused)
                }
            }
        }
    }

    private func finish() {
        guard !stopped, validateAccess() else { return }
        finishedPlayback = true
        movie.recordHouseholdProgress(watched: true, position: 0, at: Date(), household: household, session: householdSession)
    }

    /// A metadata refresh may discover a stricter certification without changing profiles.
    /// Observe those model fields so paused/buffered playback is revoked as well as future reads.
    private func observeAccess() {
        guard !stopped else { return }
        withObservationTracking {
            _ = household.allows(movie)
            _ = LibrarySearch.isAvailable(movie)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.validateAccess() else { return }
                self.observeAccess()
            }
        }
    }

    private func validateAccess() -> Bool {
        guard household.sessionIsCurrent(householdSession), household.allows(movie), LibrarySearch.isAvailable(movie) else {
            didEndNaturally = false
            playbackError = "This item is no longer available for this profile."
            stop(saveProgress: false)
            return false
        }
        return true
    }

    func stop(saveProgress: Bool = true) {
        guard !stopped else { return }
        #if CINEVAULT_COMMERCIAL
        commercialSession.stop()
        #endif
        if saveProgress { record(time: player.currentTime().seconds) }
        stopped = true
        if let embyReporter {
            let position = player.currentTime().seconds
            Task { await embyReporter.stop(position) }
            self.embyReporter = nil
        }
        if let jellyfinReporter {
            let position = player.currentTime().seconds
            Task { await jellyfinReporter.stop(seconds: position) }
            self.jellyfinReporter = nil
        }
        embyRelay?.stop()
        embyRelay = nil
        jellyfinRelay?.stop()
        jellyfinRelay = nil
        subtitles.stop()
        artworkTask?.cancel()
        artworkTask = nil
        player.pause()
        player.currentItem?.externalMetadata = []
        player.replaceCurrentItem(with: nil)
        asset.cancelLoading()
        playbackStateObservation?.invalidate()
        playbackStateObservation = nil
        itemObservation?.invalidate()
        itemObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let householdObserver { NotificationCenter.default.removeObserver(householdObserver) }
        householdObserver = nil
        timeObserver = nil
        endObserver = nil
        failureObserver = nil
        if saveProgress { try? movie.modelContext?.save() }
    }

    var permitsContinuation: Bool {
        guard !stopped, household.sessionIsCurrent(householdSession), household.allows(movie), didEndNaturally, playbackError == nil,
              player.currentItem?.forwardPlaybackEndTime.isValid != true else { return false }
        #if CINEVAULT_COMMERCIAL
        guard commercialSession.endedSuccessfully else { return false }
        #endif
        return true
    }
}

struct PlaybackScreen: View {
    @StateObject private var session: ContinuousPlayback
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @FocusState private var fixtureControl: String?
    #endif

    init(controller: PlaybackController, services: PlaybackServices, defaults: UserDefaults = .standard, library: @escaping () -> [Movie]) {
        _session = StateObject(wrappedValue: ContinuousPlayback(controller: controller, services: services, defaults: defaults, library: library,
            prepare: { try await PlaybackController.prepare(movie: $0, resume: $1, services: $2, defaults: defaults) }))
    }

    var body: some View {
        ZStack {
            ActivePlaybackView(controller: session.controller, close: close, interacting: { session.cancel() })
                .id(session.controller.movie.id)
                .allowsHitTesting(session.next == nil)
            if let next = session.next {
                NextEpisodeCountdown(session: session, suggestion: next)
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-preview-playback"),
               !ProcessInfo.processInfo.arguments.contains("--ui-preview-production-controls"), session.next == nil {
                VStack {
                    HStack {
                        Button("Fixture subtitles") {
                            session.controller.player.pause()
                            session.controller.player.seek(to: CMTime(seconds: 1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                            session.controller.subtitles.presented = true
                        }
                            .focused($fixtureControl, equals: "subtitles")
                            .accessibilityIdentifier("fixture-subtitles")
                        Button("Finish fixture episode") {
                            session.controller.player.seek(to: CMTime(seconds: 11.7, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { completed in
                                if completed { Task { @MainActor in session.controller.player.play() } }
                            }
                        }.focused($fixtureControl, equals: "finish").accessibilityIdentifier("fixture-finish-episode")
                        Text(session.controller.movie.fileName).accessibilityIdentifier("fixture-playing-episode")
                    }.padding(48)
                        .task {
                            await Task.yield()
                            await Task.yield()
                            fixtureControl = "subtitles"
                        }
                    Spacer()
                }
            }
            #endif
        }
        .onExitCommand {
            if session.next != nil { session.cancel() }
            else { close() }
        }
        .onDisappear { session.viewDisappeared() }
        .onChange(of: scenePhase) { _, phase in session.setActive(phase == .active) }
        .alert("Next episode unavailable", isPresented: Binding(get: { session.message != nil }, set: { _ in })) {
            Button("Back to library") { close() }
        } message: { Text(session.message ?? "") }
    }

    private func close() { session.stop(); dismiss() }
}

private struct ActivePlaybackView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var subtitles: PlaybackSubtitles
    let close: () -> Void
    let interacting: () -> Void

    init(controller: PlaybackController, close: @escaping () -> Void, interacting: @escaping () -> Void) {
        self.controller = controller; self.subtitles = controller.subtitles; self.close = close; self.interacting = interacting
    }

    var body: some View {
        ZStack {
        #if CINEVAULT_COMMERCIAL
            CommercialPlayerView(session: controller.commercialSession, stopsSessionOnDisappear: false)
        #else
            PlayerView(controller: controller, close: close)
        #endif
            LocalCaptionOverlay(subtitles: subtitles)
            #if CINEVAULT_COMMERCIAL
            VStack {
                HStack {
                    Button(action: close) { Label("Back", systemImage: "chevron.left") }
                    Spacer()
                    Button { subtitles.presented = true } label: { Label("Subtitles", systemImage: "captions.bubble") }
                        .accessibilityIdentifier("playback-subtitles")
                }.buttonStyle(.bordered).padding(48)
                Spacer()
            }
            #endif
        }
        .task { subtitles.start() }
        .sheet(isPresented: $subtitles.presented) { SubtitleSelectionView(subtitles: subtitles) }
        .onChange(of: subtitles.presented) { _, shown in if shown { interacting() } }
        .alert("Playback unavailable", isPresented: Binding(get: { controller.playbackError != nil }, set: { _ in })) {
            Button("Back", action: close)
        } message: { Text(controller.playbackError ?? "This file could not be played.") }
    }
}

struct PlayerView: UIViewControllerRepresentable {
    let controller: PlaybackController
    let close: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let viewController = AVPlayerViewController()
        viewController.player = controller.player
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview-playback"),
           !ProcessInfo.processInfo.arguments.contains("--ui-preview-production-controls") {
            // The fixture's own remote buttons control seeking. Native transport focus
            // is exercised independently by the production-controls launch mode.
            viewController.showsPlaybackControls = false
            viewController.view.isUserInteractionEnabled = false
        }
        #endif
        viewController.transportBarCustomMenuItems = [
            UIAction(title: "Subtitles", image: UIImage(systemName: "captions.bubble")) { _ in
                controller.subtitles.presented = true
            },
            UIAction(title: "Back", image: UIImage(systemName: "chevron.left")) { _ in
                close()
            }
        ]
        controller.player.play()
        return viewController
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: ()) {
        uiViewController.player?.pause()
    }
}

private struct NextEpisodeCountdown: View {
    @ObservedObject var session: ContinuousPlayback
    let suggestion: WatchSuggestion
    @FocusState private var playFocused: Bool
    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 26) {
                Text("Up next").font(.headline).foregroundStyle(.secondary)
                Text(suggestion.title).font(.largeTitle.bold())
                Text(suggestion.subtitle).font(.title3)
                if session.preparing { ProgressView("Opening next episode…") }
                else { Text("Playing in \(session.secondsRemaining) seconds").monospacedDigit().accessibilityIdentifier("next-episode-countdown") }
                HStack(spacing: 30) {
                    Button("Play now") { session.playNow() }
                        .focused($playFocused).disabled(session.preparing).accessibilityIdentifier("autoplay-play-now")
                    Button("Cancel") { session.cancel() }.accessibilityIdentifier("autoplay-cancel")
                }
                Text("Press Back to cancel").font(.caption).foregroundStyle(.secondary)
            }.padding(70)
        }
        .onAppear { playFocused = true }
        .onExitCommand { session.cancel() }
    }
}
