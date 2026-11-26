import CineVaultCore
import Foundation
import SwiftData

enum MetadataError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "TMDB returned an invalid response."
        case .httpStatus(401), .httpStatus(403):
            return "TMDB rejected the API key. Check it in Settings."
        case .httpStatus(let status):
            return "TMDB request failed (HTTP \(status))."
        }
    }
}

struct MetadataFetchSummary {
    let attempted: Int
    let failed: Int
    let firstError: String?

    var failureMessage: String? {
        guard failed > 0 else { return nil }
        return "Metadata failed for \(failed) of \(attempted) movies. \(firstError ?? "Try again.")"
    }
}

/// Fetches posters and details from TMDB using the user's API key.
@MainActor
final class MetadataService {
    static let shared = MetadataService()
    static let apiKeyAccount = "tmdb-api-key"
    private let requestData: (URLRequest) async throws -> (Data, URLResponse)
    private let readAPIKey: () throws -> String
    private let household: HouseholdStore
    private struct RequestIntent {
        let token: UUID
        let manual: Bool
        let adminSession: UUID?
    }
    private var requests: [UUID: RequestIntent] = [:]
    private var tvCacheKey: String?
    private var tvSearchCache: [String: [TMDBMovieSummary]] = [:]
    private var tvDetailsCache: [Int: TMDBTVDetails] = [:]
    private var tvSeasonCache: [String: TMDBTVSeason] = [:]
    private var tvContentRatingsCache: [Int: TMDBTVContentRatings] = [:]

    private func clearTVCache() {
        tvCacheKey = nil
        tvSearchCache.removeAll(); tvDetailsCache.removeAll(); tvSeasonCache.removeAll()
        tvContentRatingsCache.removeAll()
    }

    private func prepareTVCache(key: String) {
        if tvCacheKey != key || tvSearchCache.count + tvDetailsCache.count + tvSeasonCache.count + tvContentRatingsCache.count >= 512 { clearTVCache() }
        tvCacheKey = key
    }

    init(requestData: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }, readAPIKey: @escaping () throws -> String = {
        try Keychain.get(MetadataService.apiKeyAccount) ?? ""
    }, household: HouseholdStore = .shared) {
        self.requestData = requestData
        self.readAPIKey = readAPIKey
        self.household = household
    }

    /// A response may outlive a rename, reset, or manual re-match.
    private struct MatchState: Equatable {
        let id: Int?
        let title: String
        let year: Int?
        let locked: Bool
        let seriesID: Int?
        let episode: EpisodeInfo?
        let filePath: String
        let localMetadataImported: Bool?
        let localMetadataFields: [String]?

        init(_ movie: Movie) {
            id = movie.tmdbID
            title = movie.title
            year = movie.year
            locked = movie.isLocked
            seriesID = movie.seriesTMDBID
            episode = movie.episodeInfo
            filePath = movie.filePath
            localMetadataImported = movie.localMetadataImported
            localMetadataFields = movie.localMetadataFields
        }
    }

    /// Capture identity while the model is live; deleted SwiftData models can
    /// become detached while a network request or another movie is pending.
    private struct MovieReference {
        let id: UUID
        let context: ModelContext?
        let sourceID: UUID?

        init(_ movie: Movie) {
            id = movie.id
            context = movie.modelContext
            sourceID = movie.source?.id
        }

        func isAvailable(_ movie: Movie) -> Bool {
            if let context, movie.modelContext !== context { return false }
            guard !movie.isDeleted, let sourceID, let source = movie.source,
                  source.id == sourceID, !source.isDeleted else { return false }
            return !source.isIgnored(filePath: movie.filePath)
        }
    }

    private func beginRequest(for reference: MovieReference, manual: Bool) -> UUID? {
        if manual && !household.isAdmin { return nil }
        // A scan must not replace a selection the user is waiting to apply.
        if requests[reference.id]?.manual == true, !manual { return nil }
        let token = UUID()
        requests[reference.id] = RequestIntent(token: token, manual: manual,
                                              adminSession: manual ? household.sessionToken : nil)
        return token
    }

    private func requestIsCurrent(for reference: MovieReference, token: UUID) -> Bool {
        guard let intent = requests[reference.id], intent.token == token else { return false }
        if let session = intent.adminSession {
            return household.isAdmin && household.sessionIsCurrent(session)
        }
        return true
    }

    private func finishRequest(for reference: MovieReference, token: UUID) {
        if requests[reference.id]?.token == token { requests.removeValue(forKey: reference.id) }
    }

    func resetToFileName(_ movie: Movie) {
        guard household.isAdmin else { return }
        // Reset is an explicit intent even when title/ID already match the filename.
        requests.removeValue(forKey: movie.id)
        movie.resetToFileName()
    }

    var apiKey: String {
        get throws { try readAPIKey() }
    }

    func setAPIKey(_ value: String) throws {
        guard household.isAdmin else { throw HouseholdError.denied }
        try Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.apiKeyAccount)
        clearTVCache()
    }

    var hasKey: Bool {
        get throws { !(try apiKey).isEmpty }
    }

    private func load<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await requestData(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw MetadataError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw MetadataError.httpStatus(http.statusCode) }
        return try TMDB.decoder.decode(T.self, from: data)
    }

    func search(title: String, year: Int?) async throws -> [TMDBMovieSummary] {
        let key = try apiKey
        var results = try await load(TMDB.searchRequest(title: title, year: year, apiKey: key), as: TMDBSearchResponse.self).results
        if results.isEmpty, year != nil {
            results = try await load(TMDB.searchRequest(title: title, year: nil, apiKey: key), as: TMDBSearchResponse.self).results
        }
        return results
    }

    func searchTV(title: String, year: Int?) async throws -> [TMDBMovieSummary] {
        try Task.checkCancellation()
        let key = try apiKey
        prepareTVCache(key: key)
        let cacheKey = "\(TitleMatcher.normalize(title))|\(year.map(String.init) ?? "")"
        if let cached = tvSearchCache[cacheKey] { return cached }
        var results = try await load(TMDB.tvSearchRequest(title: title, year: year, apiKey: key), as: TMDBTVSearchResponse.self).results
        if results.isEmpty, year != nil {
            results = try await load(TMDB.tvSearchRequest(title: title, year: nil, apiKey: key), as: TMDBTVSearchResponse.self).results
        }
        let candidates = results.map(\.matchingCandidate)
        if tvCacheKey == key { tvSearchCache[cacheKey] = candidates }
        return candidates
    }

    private func tvDetails(id: Int) async throws -> TMDBTVDetails {
        try Task.checkCancellation()
        let key = try apiKey
        prepareTVCache(key: key)
        if let cached = tvDetailsCache[id] { return cached }
        let details = try await load(TMDB.tvDetailsRequest(id: id, apiKey: key), as: TMDBTVDetails.self)
        if tvCacheKey == key { tvDetailsCache[id] = details }
        return details
    }

    private func tvSeason(id: Int, season: Int) async throws -> TMDBTVSeason {
        try Task.checkCancellation()
        let key = try apiKey
        prepareTVCache(key: key)
        let cacheKey = "\(id)|\(season)"
        if let cached = tvSeasonCache[cacheKey] { return cached }
        let details = try await load(TMDB.tvSeasonRequest(id: id, season: season, apiKey: key), as: TMDBTVSeason.self)
        if tvCacheKey == key { tvSeasonCache[cacheKey] = details }
        return details
    }

    @discardableResult
    func applyTV(seriesID: Int, to movie: Movie, force: Bool = false) async throws -> Bool {
        guard !movie.isDeleted, let info = movie.episodeInfo else { return false }
        let reference = MovieReference(movie)
        guard let token = beginRequest(for: reference, manual: force) else { return false }
        defer { finishRequest(for: reference, token: token) }
        return try await applyTV(seriesID: seriesID, info: info, to: movie, force: force, token: token, reference: reference)
    }

    private func applyTV(seriesID: Int, info: EpisodeInfo, to movie: Movie, force: Bool,
                         token: UUID, reference: MovieReference) async throws -> Bool {
        guard reference.isAvailable(movie) else { return false }
        let original = MatchState(movie)
        let details = try await tvDetails(id: seriesID)
        let season = try await tvSeason(id: seriesID, season: info.season)
        try Task.checkCancellation()
        guard reference.isAvailable(movie), requestIsCurrent(for: reference, token: token),
              MatchState(movie) == original else { return false }
        let episode = season.episodes.first { $0.seasonNumber == info.season && $0.episodeNumber == info.episode }
        let local = force ? Set<String>() : Set(movie.localMetadataFields ?? [])
        if force { movie.localMetadataFields = nil; movie.localMetadataImported = nil; movie.localMetadataSignature = nil }
        movie.tmdbID = nil
        movie.seriesTMDBID = details.id
        if !local.contains("seriesTitle") { movie.seriesTitle = details.name.isEmpty ? info.seriesTitle : details.name }
        movie.seasonNumber = info.season
        movie.episodeNumber = info.episode
        movie.seasonPosterPath = season.posterPath
        if force || !movie.isLocked {
            if !local.contains("title"), let name = episode?.name, !name.isEmpty { movie.setTitle(name) }
            if !local.contains("year") { movie.year = details.year ?? info.year }
        }
        let episodeOverview = episode?.overview
        if !local.contains("overview") { movie.overview = episodeOverview.flatMap { $0.isEmpty ? nil : $0 } ?? details.overview }
        if !local.contains("tagline") { movie.tagline = nil }
        if !local.contains("runtime") { movie.runtimeMinutes = episode?.runtime ?? details.episodeRunTime?.first { $0 > 0 } }
        movie.rating = episode?.voteAverage ?? details.voteAverage
        if !local.contains("certification"), movie.source?.isPlex != true {
            movie.usContentRating = details.contentRatings?.usContentRating
            movie.usContentRatingFetched = details.contentRatings != nil
        }
        movie.posterPath = details.posterPath
        movie.backdropPath = episode?.stillPath ?? details.backdropPath
        if !local.contains("genres") { movie.genres = details.genres?.map(\.name) ?? [] }
        movie.metadataFetched = true
        if force { movie.isLocked = true }
        return true
    }

    private func matchTV(_ info: EpisodeInfo, movie: Movie, token: UUID, reference: MovieReference) async throws {
        let original = MatchState(movie)
        var seriesID = movie.seriesTMDBID
        if seriesID == nil {
            let results = try await searchTV(title: info.seriesTitle, year: info.year)
            seriesID = TitleMatcher.bestMatch(title: info.seriesTitle, year: info.year, in: results)?.id
        }
        try Task.checkCancellation()
        guard reference.isAvailable(movie), requestIsCurrent(for: reference, token: token),
              MatchState(movie) == original else { return }
        if let seriesID {
            _ = try await applyTV(seriesID: seriesID, info: info, to: movie, force: false, token: token, reference: reference)
        } else {
            // Remember the local grouping even without a match; never retain an old movie poster.
            if movie.tmdbID != nil {
                movie.posterPath = nil; movie.backdropPath = nil; movie.overview = nil
                movie.tagline = nil; movie.genres = []; movie.runtimeMinutes = nil; movie.rating = nil
                if !movie.isLocked { movie.setTitle(movie.parsedTitle); movie.year = info.year }
            }
            movie.tmdbID = nil
            if movie.localMetadataFields?.contains("certification") != true, movie.source?.isPlex != true {
                movie.usContentRating = nil
                movie.usContentRatingFetched = nil
            }
            movie.seriesTitle = info.seriesTitle
            movie.seasonNumber = info.season
            movie.episodeNumber = info.episode
            movie.metadataFetched = true
        }
    }

    /// Applies TMDB details to a movie. `force` is used by manual re-match.
    @discardableResult
    func apply(tmdbID: Int, to movie: Movie, force: Bool = false) async throws -> Bool {
        guard !MediaFile.isPhoto(path: movie.filePath) else { return false }
        guard !movie.isDeleted else { return false }
        let reference = MovieReference(movie)
        guard let token = beginRequest(for: reference, manual: force) else { return false }
        defer { finishRequest(for: reference, token: token) }
        return try await apply(tmdbID: tmdbID, to: movie, force: force, token: token, reference: reference)
    }

    private func apply(tmdbID: Int, to movie: Movie, force: Bool, token: UUID,
                       reference: MovieReference) async throws -> Bool {
        guard reference.isAvailable(movie) else { return false }
        let original = MatchState(movie)
        let details = try await load(TMDB.detailsRequest(id: tmdbID, apiKey: try apiKey), as: TMDBMovieDetails.self)
        guard reference.isAvailable(movie), requestIsCurrent(for: reference, token: token),
              MatchState(movie) == original else { return false }
        movie.tmdbID = details.id
        let local = force ? Set<String>() : Set(movie.localMetadataFields ?? [])
        if !local.contains("collection") {
            movie.collectionID = details.belongsToCollection?.id
            movie.collectionName = details.belongsToCollection?.name
        }
        movie.collectionLookupComplete = true
        if force { movie.localMetadataImported = nil; movie.localMetadataFields = nil; movie.localMetadataSignature = nil }
        if force || !movie.isLocked {
            if !local.contains("title") { movie.setTitle(details.title) }
            if !local.contains("year") { movie.year = details.year ?? movie.year }
        }
        if !local.contains("overview") { movie.overview = details.overview }
        if !local.contains("tagline") { movie.tagline = details.tagline }
        if !local.contains("runtime") { movie.runtimeMinutes = details.runtime }
        movie.rating = details.voteAverage
        if !local.contains("certification"), movie.source?.isPlex != true {
            movie.usContentRating = details.releaseDates?.usContentRating
            movie.usContentRatingFetched = details.releaseDates != nil
        }
        movie.posterPath = details.posterPath
        movie.backdropPath = details.backdropPath
        if !local.contains("genres") { movie.genres = details.genres?.map(\.name) ?? [] }
        movie.metadataFetched = true
        if force { movie.isLocked = true }
        return true
    }

    /// Auto-match: uses a {tmdb-123} tag if present, otherwise title/year search.
    func match(_ movie: Movie) async throws {
        guard !movie.isDeleted, !movie.isMissing, movie.source?.isIgnored(filePath: movie.filePath) != true else { return }
        guard !MediaFile.isAudio(path: movie.filePath), !MediaFile.isPhoto(path: movie.filePath) else { movie.metadataFetched = true; return }
        let reference = MovieReference(movie)
        guard let token = beginRequest(for: reference, manual: false) else { return }
        defer { finishRequest(for: reference, token: token) }
        if let info = movie.episodeInfo {
            try await matchTV(info, movie: movie, token: token, reference: reference)
            return
        }
        let original = MatchState(movie)
        if let id = movie.tmdbID {
            _ = try await apply(tmdbID: id, to: movie, force: false, token: token, reference: reference)
            return
        }
        let title = movie.isLocked || movie.localMetadataImported == true ? movie.title : movie.parsedTitle
        let year = movie.isLocked || movie.localMetadataImported == true ? movie.year : movie.parsedYear
        guard !title.isEmpty else { return }
        let results = try await search(title: title, year: year)
        guard reference.isAvailable(movie), requestIsCurrent(for: reference, token: token),
              MatchState(movie) == original else { return }
        if let best = TitleMatcher.bestMatch(title: title, year: year, in: results) {
            _ = try await apply(tmdbID: best.id, to: movie, force: false, token: token, reference: reference)
        } else {
            if movie.localMetadataFields?.contains("certification") != true, movie.source?.isPlex != true {
                movie.usContentRating = nil
                movie.usContentRatingFetched = nil
            }
            movie.metadataFetched = true
        }
    }

    /// Refresh just the certification of an already matched item. In particular,
    /// upgrading a library must not replace a user's title, artwork or progress.
    func fetchUSContentRating(for movie: Movie) async throws {
        guard movie.localMetadataFields?.contains("certification") != true else { return }
        guard !movie.isDeleted, !movie.isMissing, movie.source?.isPlex != true, try hasKey,
              !MediaFile.isAudio(path: movie.filePath), !MediaFile.isPhoto(path: movie.filePath) else { return }
        let reference = MovieReference(movie)
        guard reference.isAvailable(movie), let token = beginRequest(for: reference, manual: false) else { return }
        defer { finishRequest(for: reference, token: token) }
        let original = MatchState(movie)
        let key = try apiKey
        let rating: String?
        if let seriesID = movie.seriesTMDBID {
            prepareTVCache(key: key)
            let response: TMDBTVContentRatings
            if let cached = tvContentRatingsCache[seriesID] ?? tvDetailsCache[seriesID]?.contentRatings {
                response = cached
            } else {
                response = try await load(TMDB.tvContentRatingsRequest(id: seriesID, apiKey: key), as: TMDBTVContentRatings.self)
                if tvCacheKey == key { tvContentRatingsCache[seriesID] = response }
            }
            rating = response.usContentRating
        } else if let tmdbID = movie.tmdbID, movie.episodeInfo == nil {
            let response = try await load(TMDB.movieReleaseDatesRequest(id: tmdbID, apiKey: key), as: TMDBMovieReleaseDates.self)
            rating = response.usContentRating
        } else {
            // Unmatched titles and legacy TV rows with a movie ID remain unrated.
            return
        }
        try Task.checkCancellation()
        guard reference.isAvailable(movie), requestIsCurrent(for: reference, token: token),
              MatchState(movie) == original else { return }
        movie.usContentRating = rating
        movie.usContentRatingFetched = true
    }

    func fetchMissing(in context: ModelContext) async throws -> MetadataFetchSummary? {
        guard try hasKey else { return nil }
        let descriptor = FetchDescriptor<Movie>(predicate: #Predicate { !$0.isMissing })
        func needsMatch(_ movie: Movie) -> Bool {
            !movie.metadataFetched || (!movie.isLocked && movie.seriesTitle == nil && movie.episodeInfo != nil)
        }
        let movies = try context.fetch(descriptor).filter {
            !$0.isMissing && $0.source?.isIgnored(filePath: $0.filePath) != true &&
                !MediaFile.isAudio(path: $0.filePath) && !MediaFile.isPhoto(path: $0.filePath) &&
                (needsMatch($0) || ($0.usContentRatingFetched != true &&
                    ($0.seriesTMDBID != nil || ($0.tmdbID != nil && $0.episodeInfo == nil))))
        }
        return try await update(movies, in: context) {
            if needsMatch($0) { try await self.match($0) }
            else { try await self.fetchUSContentRating(for: $0) }
        }
    }

    func refreshCollections(in context: ModelContext) async throws -> MetadataFetchSummary? {
        guard try hasKey else { return nil }
        let movies = try context.fetch(FetchDescriptor<Movie>()).filter {
            !$0.isMissing && $0.episodeInfo == nil && $0.tmdbID != nil && $0.localMetadataFields?.contains("collection") != true
        }
        return try await update(movies, in: context) { try await self.fetchCollection(for: $0) }
    }

    /// Backfill grouping alone without changing a matched title, artwork or viewing history.
    private func fetchCollection(for movie: Movie) async throws {
        guard let id = movie.tmdbID, movie.episodeInfo == nil else { return }
        let reference = MovieReference(movie)
        guard reference.isAvailable(movie), let token = beginRequest(for: reference, manual: false) else { return }
        defer { finishRequest(for: reference, token: token) }
        let original = MatchState(movie)
        let details = try await load(TMDB.detailsRequest(id: id, apiKey: try apiKey), as: TMDBMovieDetails.self)
        guard reference.isAvailable(movie), requestIsCurrent(for: reference, token: token), MatchState(movie) == original,
              movie.localMetadataFields?.contains("collection") != true else { return }
        movie.collectionID = details.belongsToCollection?.id
        movie.collectionName = details.belongsToCollection?.name
        movie.collectionLookupComplete = true
    }

    func update(_ movies: [Movie], in context: ModelContext,
                match: (Movie) async throws -> Void) async throws -> MetadataFetchSummary {
        clearTVCache()
        let pending = movies.filter { !$0.isDeleted }.map { ($0, MovieReference($0)) }
        var attempted = 0
        var failed = 0
        var firstError: String?
        for (movie, reference) in pending {
            try Task.checkCancellation()
            guard reference.isAvailable(movie) else { continue }
            attempted += 1
            do {
                try await match(movie)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
                continue
            }
            try context.save()
        }
        return MetadataFetchSummary(attempted: attempted, failed: failed, firstError: firstError)
    }
}
