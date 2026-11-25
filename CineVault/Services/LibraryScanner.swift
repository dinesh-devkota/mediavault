import CineVaultCore
import Foundation
import SwiftData

/// Walks a NAS source and syncs Movie rows with the files found.
@MainActor
final class LibraryScanner: ObservableObject {
    @Published private(set) var isScanning = false
    @Published var status: String?
    private let scanVideos: (SourceConfig) async throws -> [RemoteFile]
    private let scanWithProgress: ((SourceConfig, MediaScanReporter) async throws -> [RemoteFile])?
    private let saveContext: (ModelContext) throws -> Void
    private let fetchMetadata: (ModelContext) async throws -> MetadataFetchSummary?
    private let importLocalMetadata: ((MediaSource, ModelContext, SourceConfig) async throws -> Void)?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(fetchMetadata: ((ModelContext) async throws -> MetadataFetchSummary?)? = nil,
         scanVideos: ((SourceConfig) async throws -> [RemoteFile])? = nil,
         scanWithProgress: ((SourceConfig, MediaScanReporter) async throws -> [RemoteFile])? = nil,
         saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() },
         importLocalMetadata: ((MediaSource, ModelContext, SourceConfig) async throws -> Void)? = nil) {
        self.saveContext = saveContext
        self.fetchMetadata = fetchMetadata ?? { try await MetadataService.shared.fetchMissing(in: $0) }
        self.importLocalMetadata = importLocalMetadata ?? (scanVideos == nil && scanWithProgress == nil ? { source, context, config in
            _ = try await LocalMetadataService.shared.importFiles(source: source, context: context, config: config)
        } : nil)
        self.scanVideos = scanVideos ?? { try await SMBService.shared.scanVideos($0) }
        if let scanWithProgress { self.scanWithProgress = scanWithProgress }
        else if scanVideos == nil {
            self.scanWithProgress = { config, report in
                try await SMBService.shared.scanMedia(config, onProgress: report)
            }
        } else { self.scanWithProgress = nil }
    }

    func scan(_ source: MediaSource, context: ModelContext) async {
        if isScanning {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isScanning = true
        }
        defer {
            if waiters.isEmpty {
                isScanning = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        guard !Task.isCancelled else { return }
        status = "Scanning \(source.name)…"
        do {
            let config = try source.config()
            if config.isJellyfin {
                try await scanJellyfin(source, config: config, context: context)
                return
            }
            let state = LibraryScanState(source: source, context: context, config: config, saveContext: saveContext)
            let scannedFiles: [RemoteFile]
            if let scanWithProgress {
                scannedFiles = try await scanWithProgress(config) { progress in
                    try state.apply(progress.files)
                    self.status = "Scanning \(source.name): \(state.foundCount) items in \(progress.folders) folders…"
                }
            } else { scannedFiles = try await scanVideos(config) }
            try Task.checkCancellation()
            try state.verifySource()
            let files = scannedFiles.filter { !config.excludesFile($0.path) && MediaFile.shouldIndex(path: $0.path, size: $0.size) }
            var existing = Dictionary(source.movies.map { (Data($0.filePath.utf8), $0) }, uniquingKeysWith: { a, _ in a })
            let previous = existing.values.map { ($0, $0.isMissing, $0.fileSize) }
            let previousScanDate = source.lastScanDate
            var finalInsertions: [Movie] = []
            for file in files {
                if let movie = existing.removeValue(forKey: Data(file.path.utf8)) {
                    movie.isMissing = false
                    movie.fileSize = file.size
                    continue
                }
                finalInsertions.append(state.insert(file))
            }
            for movie in existing.values { movie.isMissing = true }
            source.lastScanDate = Date()
            do { try saveContext(context) }
            catch {
                for (movie, missing, size) in previous { movie.isMissing = missing; movie.fileSize = size }
                source.lastScanDate = previousScanDate
                for movie in finalInsertions { context.delete(movie) }
                throw error
            }
            func scanSummary() -> String {
                let counts = Dictionary(grouping: source.movies.filter { !$0.isMissing }, by: \.mediaKind)
                return "\(source.name): \(counts[.movie]?.count ?? 0) movies, \(counts[.documentary]?.count ?? 0) documentaries, \(counts[.tvShow]?.count ?? 0) TV episodes, \(counts[.music]?.count ?? 0) music items, \(counts[.photo]?.count ?? 0) photos (\(state.added) new)"
            }
            status = scanSummary()
            do {
                if let importLocalMetadata { try await importLocalMetadata(source, context, config) }
                let result = try await fetchMetadata(context)
                let complete = scanSummary()
                status = complete
                if let failure = result?.failureMessage {
                    status = "\(complete). \(failure)"
                }
            } catch {
                status = "\(scanSummary()). Metadata update failed: \(error.localizedDescription)"
            }
        } catch is CancellationError {
            status = "Scan cancelled for \(source.name)."
        } catch {
            let reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let separator = reason.hasSuffix(".") ? " " : ". "
            status = "Scan failed for \(source.name): \(reason)\(separator)Items already found are kept. Retry from Sources."
        }
    }

    private func scanJellyfin(_ source: MediaSource, config: SourceConfig, context: ModelContext) async throws {
        let household = HouseholdStore.shared
        let session = household.sessionToken
        guard household.isAdmin, JellyfinSourceConnection.validItemID(config.share) else { throw HouseholdError.denied }
        let connection = try JellyfinSourceConnection(config: config)
        var catalog: [(String, JellyfinCatalogItem)] = []
        var seriesTMDBIDs: [String: Int] = [:]
        try await connection.client.catalog(connection.account, libraryID: config.share) { items in
            guard household.sessionIsCurrent(session), household.isAdmin else { throw HouseholdError.denied }
            for item in items {
                if item.type == "Series", let id = item.tmdbID { seriesTMDBIDs[item.id] = id }
                if let path = JellyfinSourceConnection.mediaPath(item) { catalog.append((path, item)) }
            }
            self.status = "Scanning \(source.name): \(catalog.count) items…"
        }
        try Task.checkCancellation()
        guard household.sessionIsCurrent(session), household.isAdmin,
              !source.isDeleted, try source.config() == config else { throw SMBError.sourceChanged }

        let indexed = source.movies.compactMap { movie -> (String, Movie)? in
            guard let id = try? JellyfinSourceConnection.itemID(for: movie.filePath) else { return nil }
            return (id, movie)
        }
        var existing = Dictionary(indexed, uniquingKeysWith: { first, _ in first })
        let date = source.lastScanDate
        var inserted: [Movie] = []
        var undo: [() -> Void] = []
        for (path, item) in catalog {
            let movie: Movie
            if let current = existing.removeValue(forKey: item.id) {
                let previous = (current.filePath, current.isMissing, current.seriesTitle, current.providerSeriesID,
                                current.seasonNumber, current.episodeNumber, current.usContentRating, current.usContentRatingFetched,
                                current.providerImageTag, current.tmdbID, current.seriesTMDBID)
                undo.append {
                    (current.filePath, current.isMissing, current.seriesTitle, current.providerSeriesID,
                     current.seasonNumber, current.episodeNumber, current.usContentRating, current.usContentRatingFetched,
                     current.providerImageTag, current.tmdbID, current.seriesTMDBID) = previous
                }
                movie = current
            } else {
                movie = Movie(filePath: path, fileSize: 0, source: source)
                movie.fileName = item.name
                movie.parsedTitle = item.name
                movie.setTitle(item.name)
                movie.parsedYear = item.year
                movie.year = item.year
                movie.overview = item.overview
                movie.metadataFetched = true
                context.insert(movie)
                inserted.append(movie)
            }
            movie.filePath = path
            movie.isMissing = false
            movie.seriesTitle = item.seriesName
            movie.providerSeriesID = item.seriesID
            movie.seasonNumber = item.season
            movie.episodeNumber = item.number
            movie.usContentRating = item.rating
            movie.usContentRatingFetched = true
            movie.providerImageTag = item.primaryImage?["Primary"]
            if item.type == "Movie", movie.tmdbID == nil {
                movie.tmdbID = item.tmdbID
            }
            if item.type == "Episode", movie.seriesTMDBID == nil, let seriesID = item.seriesID {
                movie.seriesTMDBID = seriesTMDBIDs[seriesID]
            }
        }
        for movie in existing.values where !movie.isMissing {
            undo.append { movie.isMissing = false }
            movie.isMissing = true
        }
        source.lastScanDate = Date()
        do { try saveContext(context) }
        catch {
            for restore in undo.reversed() { restore() }
            source.lastScanDate = date
            for movie in inserted { context.delete(movie) }
            throw error
        }
        status = "\(source.name): \(catalog.count) items (\(inserted.count) new)"
    }

    func scanAll(context: ModelContext) async {
        do {
            let sources = try context.fetch(FetchDescriptor<MediaSource>())
            for source in sources { await scan(source, context: context) }
        } catch {
            status = "Could not load NAS sources: \(error.localizedDescription)"
        }
    }
}

/// SwiftData state stays on the main actor while the SMB actor walks the network.
@MainActor
private final class LibraryScanState {
    let source: MediaSource
    let context: ModelContext
    let config: SourceConfig
    private(set) var added = 0
    private var foundPaths: Set<Data> = []
    var foundCount: Int { foundPaths.count }
    private var indexed: [Data: Movie]
    private let saveContext: (ModelContext) throws -> Void
    init(source: MediaSource, context: ModelContext, config: SourceConfig,
         saveContext: @escaping (ModelContext) throws -> Void) {
        self.source = source; self.context = context; self.config = config
        self.saveContext = saveContext
        indexed = Dictionary(source.movies.map { (Data($0.filePath.utf8), $0) }, uniquingKeysWith: { a, _ in a })
    }
    func verifySource() throws {
        try Task.checkCancellation()
        guard !source.isDeleted, source.modelContext != nil else { throw SMBError.sourceChanged }
        guard try source.config() == config else { throw SMBError.sourceChanged }
    }
    func apply(_ files: [RemoteFile]) throws {
        try verifySource()
        let files = files.filter { !config.excludesFile($0.path) && MediaFile.shouldIndex(path: $0.path, size: $0.size) }
        guard !files.isEmpty else { return }
        var previous: [(Movie, Bool, Int64)] = []
        var inserted: [Movie] = []
        for file in files {
            if let movie = indexed[Data(file.path.utf8)], !movie.isDeleted {
                previous.append((movie, movie.isMissing, movie.fileSize))
                movie.isMissing = false; movie.fileSize = file.size
            } else { inserted.append(insert(file)) }
        }
        do { try saveContext(context) }
        catch {
            for (movie, missing, size) in previous.reversed() { movie.isMissing = missing; movie.fileSize = size }
            for movie in inserted { indexed.removeValue(forKey: Data(movie.filePath.utf8)); context.delete(movie) }
            added -= inserted.count
            throw error
        }
        foundPaths.formUnion(files.map { Data($0.path.utf8) })
    }
    @discardableResult
    func insert(_ file: RemoteFile) -> Movie {
        let movie = Movie(filePath: file.path, fileSize: file.size, source: source)
        let parsed = FilenameParser.parse(path: file.path)
        let localOnly = MediaFile.isAudio(path: file.path) || MediaFile.isPhoto(path: file.path)
        let title = localOnly ? (movie.fileName as NSString).deletingPathExtension : parsed.title
        movie.parsedTitle = title
        movie.parsedYear = localOnly ? nil : parsed.year
        movie.tmdbID = localOnly ? nil : parsed.tmdbID
        movie.setTitle(title.isEmpty ? movie.fileName : title)
        movie.year = localOnly ? nil : parsed.year
        movie.metadataFetched = localOnly
        context.insert(movie)
        indexed[Data(file.path.utf8)] = movie
        added += 1
        return movie
    }
}
