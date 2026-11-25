import CineVaultCore
import Foundation
import SwiftData

/// Reads metadata next to media. It never writes to a source or follows links contained in XML.
@MainActor
final class LocalMetadataService {
    static let shared = LocalMetadataService()
    typealias List = (SourceConfig, String) async throws -> [NASDirectoryEntry]
    typealias Size = (SourceConfig, String) async throws -> Int64
    typealias Read = (SourceConfig, String, Int) async throws -> Data
    private let list: List
    private let size: Size
    private let read: Read

    init(list: @escaping List = { try await SMBService.shared.listEntries($0, directory: $1) },
         size: @escaping Size = { try await SMBService.shared.fileSize($0, path: $1) },
         read: @escaping Read = { try await SMBService.shared.read($0, path: $1, offset: 0, length: $2) }) {
        self.list = list; self.size = size; self.read = read
    }

    /// Returns recognized artwork paths so imported posters do not become unrelated photo albums.
    func importFiles(source: MediaSource, context: ModelContext, config: SourceConfig) async throws -> Set<String> {
        guard !config.isJellyfin else { return [] } // Server catalog metadata/artwork owns these items.
        let videos = source.movies.filter { !$0.isMissing && !MediaFile.isPhoto(path: $0.filePath) && !MediaFile.isAudio(path: $0.filePath) }
        let byDirectory = Dictionary(grouping: videos, by: { ($0.filePath as NSString).deletingLastPathComponent })
        var entries: [String: [String]] = [:]
        var xml: [String: LocalMediaMetadata] = [:]
        var failedXML: Set<String> = []
        var artwork: Set<String> = []

        func verify() throws {
            try Task.checkCancellation()
            guard !source.isDeleted, source.modelContext != nil, try source.config() == config else { throw SMBError.sourceChanged }
        }
        func allowed(_ path: String, directory: Bool = false) -> Bool {
            PhotoLocation.contains(path: path, root: config.rootPath, caseSensitive: config.isWebDAV) &&
                (directory ? !config.excludesDirectory(path) : !config.excludesFile(path))
        }
        func directoryEntries(_ directory: String) async throws -> [String] {
            if let cached = entries[directory] { return cached }
            guard directory == config.rootPath || allowed(directory, directory: true) else { return [] }
            let result = try await list(config, directory)
            try verify()
            guard result.count <= 25_000 else { return [] }
            let paths = result.filter { !$0.isDirectory && !$0.name.isEmpty && !$0.name.contains("/") && !$0.name.contains("\\") }
                .map { LocalMediaSidecars.join(directory, $0.name) }.filter { allowed($0) }
            entries[directory] = paths
            return paths
        }
        func find(_ candidates: [String], in values: [String]) -> String? {
            candidates.lazy.compactMap { wanted in values.first { config.isWebDAV ? Data($0.utf8) == Data(wanted.utf8) : $0.caseInsensitiveCompare(wanted) == .orderedSame } }.first
        }
        func metadata(_ path: String?) async throws -> LocalMediaMetadata? {
            guard let path else { return nil }
            if let cached = xml[path] { return cached }
            if failedXML.contains(path) { return nil }
            do {
                let bytes = try await size(config, path)
                try verify()
                guard bytes > 0, bytes <= Int64(LocalMetadataParser.maximumBytes) else { failedXML.insert(path); return nil }
                let data = try await read(config, path, Int(bytes))
                try verify()
                guard Int64(data.count) == bytes else { failedXML.insert(path); return nil }
                let value = try LocalMetadataParser.parse(data)
                xml[path] = value
                return value
            } catch is CancellationError { throw CancellationError() }
            catch SMBError.sourceChanged { throw SMBError.sourceChanged }
            catch { failedXML.insert(path); return nil }
        }

        for directory in byDirectory.keys.sorted() {
            try verify()
            let folderMovies = byDirectory[directory] ?? []
            let names: [String]
            do { names = try await directoryEntries(directory) }
            catch is CancellationError { throw CancellationError() }
            catch SMBError.sourceChanged { throw SMBError.sourceChanged }
            catch { continue } // A sidecar lookup never makes otherwise playable media unavailable.
            for movie in folderMovies {
                let path = movie.filePath
                let single = folderMovies.count == 1
                let metadataPath = find(LocalMediaSidecars.metadataCandidates(video: path, singleVideo: single), in: names)
                var sidecarExists = metadataPath != nil
                var parentListingFailed = false
                let info = try await metadata(metadataPath)
                var showInfo: LocalMediaMetadata?
                var seasonInfo: LocalMediaMetadata?
                var showNames: [String] = []
                var showDirectory = directory
                let isEpisode = movie.episodeInfo != nil || info?.kind == "episodedetails"
                if isEpisode {
                    let seasonPath = find([LocalMediaSidecars.join(directory, "season.nfo")], in: names)
                    let showPath = find([LocalMediaSidecars.join(directory, "tvshow.nfo")], in: names)
                    sidecarExists = sidecarExists || seasonPath != nil || showPath != nil
                    seasonInfo = try await metadata(seasonPath)
                    showInfo = try await metadata(showPath)
                    showNames = names
                    if showInfo == nil {
                        let parent = (directory as NSString).deletingLastPathComponent
                        if parent != directory, parent == config.rootPath || allowed(parent, directory: true) {
                            do {
                                let parentNames = try await directoryEntries(parent)
                                showDirectory = parent; showNames = parentNames
                                let parentShowPath = find([LocalMediaSidecars.join(parent, "tvshow.nfo")], in: parentNames)
                                sidecarExists = sidecarExists || parentShowPath != nil
                                showInfo = try await metadata(parentShowPath)
                            } catch is CancellationError { throw CancellationError() }
                            catch SMBError.sourceChanged { throw SMBError.sourceChanged }
                            catch { parentListingFailed = true }
                        }
                    }
                }
                let poster = find(LocalMediaSidecars.artworkCandidates(video: path, backdrop: false, singleVideo: single && !isEpisode), in: names)
                let fanart = find(LocalMediaSidecars.artworkCandidates(video: path, backdrop: true, singleVideo: single && !isEpisode), in: names)
                let showPoster = isEpisode ? find(["poster.jpg", "poster.png", "poster.jpeg", "poster.webp", "folder.jpg", "folder.png", "folder.jpeg", "folder.webp"].map { LocalMediaSidecars.join(showDirectory, $0) }, in: showNames) : nil
                let showFanart = isEpisode ? find(["fanart.jpg", "fanart.png", "fanart.jpeg", "fanart.webp"].map { LocalMediaSidecars.join(showDirectory, $0) }, in: showNames) : nil
                let season = info?.season ?? seasonInfo?.season ?? movie.episodeInfo?.season
                let seasonPoster = season.flatMap { number in
                    let stems = [LocalMediaSidecars.join(directory, "poster"), LocalMediaSidecars.join(directory, "folder"),
                        LocalMediaSidecars.join(showDirectory, String(format: "season%02d-poster", number)),
                        LocalMediaSidecars.join(showDirectory, "season \(number)-poster")]
                    return find(stems.flatMap { stem in ["jpg", "png", "jpeg", "webp"].map { stem + "." + $0 } }, in: names + showNames)
                }
                try verify()
                guard !movie.isDeleted, movie.filePath == path, movie.source?.id == source.id else { continue }
                movie.localPosterPath = isEpisode ? (showPoster ?? poster) : poster
                movie.localBackdropPath = fanart ?? (isEpisode ? poster : nil) ?? showFanart
                movie.localSeasonPosterPath = seasonPoster
                [poster, fanart, showPoster, showFanart, seasonPoster].compactMap { $0 }.forEach { artwork.insert($0) }
                if !movie.isLocked {
                    if info != nil || showInfo != nil || seasonInfo != nil {
                        Self.apply(info, show: showInfo, season: seasonInfo, to: movie)
                    } else if movie.localMetadataImported == true {
                        // Only a successfully listed directory proves removal. A malformed/unreadable
                        // sidecar still fails closed for its previous local age certification.
                        if movie.localMetadataFields?.contains("certification") == true {
                            movie.usContentRating = nil; movie.usContentRatingFetched = nil
                            movie.localMetadataSignature = nil
                        }
                        if !sidecarExists && !parentListingFailed { Self.clearOverrides(movie) }
                    }
                }
            }
        }
        try verify()
        for photo in source.movies where MediaFile.isPhoto(path: photo.filePath) && artwork.contains(photo.filePath) { photo.isMissing = true }
        try context.save()
        return artwork
    }

    static func apply(_ info: LocalMediaMetadata?, show: LocalMediaMetadata? = nil, season: LocalMediaMetadata? = nil, to movie: Movie) {
        guard !movie.isLocked else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let signature = try? encoder.encode([info, show, season])
        if signature != nil && movie.localMetadataSignature == signature { return }
        let previousFields = Set(movie.localMetadataFields ?? [])
        var fields: Set<String> = []
        if let title = info?.title { movie.setTitle(title); fields.insert("title") }
        if let year = info?.year ?? show?.year { movie.year = year; fields.insert("year") }
        if let plot = info?.plot { movie.overview = plot; fields.insert("overview") }
        if let tagline = info?.tagline { movie.tagline = tagline; fields.insert("tagline") }
        let genres = info?.genres.isEmpty == false ? info?.genres : show?.genres
        if let genres, !genres.isEmpty { movie.genres = genres; fields.insert("genres") }
        if let runtime = info?.runtime { movie.runtimeMinutes = runtime; fields.insert("runtime") }
        if info?.certificationPresent == true || show?.certificationPresent == true {
            movie.usContentRating = info?.certificationPresent == true ? info?.certification : show?.certification
            movie.usContentRatingFetched = true; fields.insert("certification")
        }
        movie.localEdition = info?.edition
        if info?.kind == "episodedetails" || movie.episodeInfo != nil {
            movie.seriesTitle = info?.showTitle ?? show?.title ?? movie.seriesTitle ?? movie.episodeInfo?.seriesTitle
            if info?.showTitle != nil || show?.title != nil { fields.insert("seriesTitle") }
            movie.seasonNumber = info?.season ?? season?.season ?? movie.episodeInfo?.season
            movie.episodeNumber = info?.episode ?? movie.episodeInfo?.episode
            if info?.season != nil || season?.season != nil { fields.insert("seasonNumber") }
            if info?.episode != nil { fields.insert("episodeNumber") }
            if let id = show?.tmdbID { movie.seriesTMDBID = id; fields.insert("seriesTMDBID") }
            movie.tmdbID = nil
        } else if let id = info?.tmdbID { movie.tmdbID = id; fields.insert("tmdbID") }
        if let name = info?.collection { movie.collectionName = name; movie.collectionID = nil; fields.insert("collection") }
        clearFields(previousFields.subtracting(fields), movie: movie)
        movie.localMetadataImported = true
        movie.localMetadataFields = fields.sorted()
        movie.localMetadataSignature = signature
        // These are local fields, not a claim that an online fetch has completed.
        movie.metadataFetched = false
    }

    static func clearOverrides(_ movie: Movie) {
        guard !movie.isLocked else { return }
        clearFields(Set(movie.localMetadataFields ?? []), movie: movie)
        movie.localMetadataFields = nil; movie.localMetadataImported = nil; movie.localMetadataSignature = nil
        movie.localEdition = nil; movie.metadataFetched = false
    }

    private static func clearFields(_ fields: Set<String>, movie: Movie) {
        if fields.contains("title") { movie.setTitle(movie.parsedTitle.isEmpty ? movie.fileName : movie.parsedTitle) }
        if fields.contains("year") { movie.year = movie.parsedYear }
        if fields.contains("overview") { movie.overview = nil }
        if fields.contains("tagline") { movie.tagline = nil }
        if fields.contains("genres") { movie.genres = [] }
        if fields.contains("runtime") { movie.runtimeMinutes = nil }
        if fields.contains("certification") { movie.usContentRating = nil; movie.usContentRatingFetched = nil }
        if fields.contains("collection") { movie.collectionName = nil; movie.collectionID = nil; movie.collectionLookupComplete = nil }
        if fields.contains("seriesTitle") { movie.seriesTitle = EpisodeParser.parse(path: movie.filePath)?.seriesTitle }
        if fields.contains("seasonNumber") { movie.seasonNumber = EpisodeParser.parse(path: movie.filePath)?.season }
        if fields.contains("episodeNumber") { movie.episodeNumber = EpisodeParser.parse(path: movie.filePath)?.episode }
        if fields.contains("tmdbID") { movie.tmdbID = nil }
        if fields.contains("seriesTMDBID") { movie.seriesTMDBID = nil }
    }

}
