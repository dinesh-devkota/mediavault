import CineVaultCore
import Foundation

struct ShowSearchResult: Identifiable {
    let show: TVShowGroup
    let matchingEpisodeCount: Int?
    var id: String { show.id }
    var subtitle: String {
        if let count = matchingEpisodeCount { return "\(count) matching episodes" }
        let seasons = show.seasons.count
        let count = Set(show.episodes.map { SearchEpisodeResult.logicalID($0, showID: show.id) }).count
        return "\(seasons) \(seasons == 1 ? "season" : "seasons") · \(count) \(count == 1 ? "episode" : "episodes")"
    }
}

struct SearchEpisodeResult: Identifiable {
    let showID: String
    let showTitle: String
    let movie: Movie
    var id: String { Self.logicalID(movie, showID: showID) }
    var subtitle: String {
        let season = TVShowGroup.season(movie), episode = TVShowGroup.episode(movie)
        return "\(showTitle) · S\(season) E\(episode)"
    }
    static func logicalID(_ movie: Movie, showID: String) -> String {
        let season = TVShowGroup.season(movie), episode = TVShowGroup.episode(movie)
        guard season >= 0, episode != Int.max else { return "\(showID)|file:\(movie.id)" }
        return "\(showID)|s:\(season)|e:\(episode)"
    }
}

struct LibrarySearchResults {
    var titles: [Movie] = []
    var shows: [ShowSearchResult] = []
    var episodes: [SearchEpisodeResult] = []
    var photos: [Movie] = []
    var count: Int { titles.count + shows.count + episodes.count + photos.count }
    var isEmpty: Bool { count == 0 }
    var focusIDs: Set<String> {
        Set(titles.map { "title:\($0.id)" } + shows.map { "show:\($0.id)" } + episodes.map { "episode:\($0.id)" })
    }

    func movieID(forFocusID id: String) -> UUID? {
        if let title = titles.first(where: { "title:\($0.id)" == id }) { return title.id }
        if let episode = episodes.first(where: { "episode:\($0.id)" == id }) { return episode.movie.id }
        return shows.first(where: { "show:\($0.id)" == id })?.show.episodes.first?.id
    }

    func focusID(containing movieID: UUID) -> String? {
        if let title = titles.first(where: { $0.id == movieID }) { return "title:\(title.id)" }
        if let episode = episodes.first(where: { $0.movie.id == movieID }) { return "episode:\(episode.id)" }
        return shows.first(where: { $0.show.episodes.contains { $0.id == movieID } }).map { "show:\($0.id)" }
    }
}

extension LibrarySearch {
    /// Build complete eligible series before matching so a search never truncates the destination's seasons.
    @MainActor
    static func results(in movies: [Movie], text: String) -> LibrarySearchResults {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = TitleMatcher.normalize(query)
        guard !normalized.isEmpty else { return LibrarySearchResults() }
        var result = LibrarySearchResults()
        var seriesEpisodes: [Movie] = []
        for movie in movies where !movie.isDeleted && !movie.isMissing && !movie.isHidden {
            if let source = movie.source {
                guard !source.isDeleted, PhotoLocation.contains(path: movie.filePath, root: source.rootPath),
                      !source.isIgnored(filePath: movie.filePath) else { continue }
            }
            switch movie.mediaKind {
            case .tvShow:
                if movie.source != nil { seriesEpisodes.append(movie) }
            case .photo:
                if movie.source != nil && matches(movie, text: query, normalized: normalized) { result.photos.append(movie) }
            default:
                if matches(movie, text: query, normalized: normalized) { result.titles.append(movie) }
            }
        }
        result.titles.sort { $0.sortTitle < $1.sortTitle }
        result.photos.sort { $0.sortTitle < $1.sortTitle }
        for show in TVShowGroup.groups(seriesEpisodes) {
            let nameMatch = show.episodes.contains { movie in
                let local = EpisodeParser.parse(path: movie.filePath)
                let names: [(String?, Int?)] = [(movie.seriesTitle, movie.year), (movie.episodeInfo?.seriesTitle, movie.episodeInfo?.year),
                    (local?.seriesTitle, local?.year)]
                return names.contains { name, year in
                    guard let name, !name.isEmpty else { return false }
                    return contains(normalized, in: name) ||
                        year.map { normalized.hasSuffix(" \($0)") &&
                            TitleMatcher.normalize("\(name) \($0)").contains(normalized) } == true
                }
            }
            let genreMatch = show.episodes.contains { $0.genres.contains { contains(normalized, in: $0) } }
            if nameMatch || genreMatch {
                result.shows.append(ShowSearchResult(show: show, matchingEpisodeCount: nil))
                continue
            }
            let matching = show.episodes.filter { episodeMatches($0, normalized: normalized) }
            let logical = Dictionary(grouping: matching) { SearchEpisodeResult.logicalID($0, showID: show.id) }
            if logical.count > 3 {
                result.shows.append(ShowSearchResult(show: show, matchingEpisodeCount: logical.count))
            } else {
                for versions in logical.values {
                    let selected = versions.sorted { left, right in
                        let leftExact = TitleMatcher.normalize(left.fileName) == normalized
                        let rightExact = TitleMatcher.normalize(right.fileName) == normalized
                        if leftExact != rightExact { return leftExact }
                        let path = left.filePath.compare(right.filePath, options: [.caseInsensitive])
                        if path != .orderedSame { return path == .orderedAscending }
                        let leftSource = left.source?.id.uuidString ?? "", rightSource = right.source?.id.uuidString ?? ""
                        return leftSource == rightSource ? left.id.uuidString < right.id.uuidString : leftSource < rightSource
                    }.first!
                    result.episodes.append(SearchEpisodeResult(showID: show.id, showTitle: show.title, movie: selected))
                }
            }
        }
        result.shows.sort {
            let order = $0.show.title.localizedStandardCompare($1.show.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        result.episodes.sort {
            let title = $0.showTitle.localizedStandardCompare($1.showTitle)
            if title != .orderedSame { return title == .orderedAscending }
            let leftSeason = TVShowGroup.season($0.movie), rightSeason = TVShowGroup.season($1.movie)
            if leftSeason != rightSeason { return leftSeason < rightSeason }
            let leftEpisode = TVShowGroup.episode($0.movie), rightEpisode = TVShowGroup.episode($1.movie)
            return leftEpisode == rightEpisode ? $0.id < $1.id : leftEpisode < rightEpisode
        }
        return result
    }

    private static func episodeMatches(_ movie: Movie, normalized: String) -> Bool {
        let season = TVShowGroup.season(movie), episode = TVShowGroup.episode(movie)
        let codes = season >= 0 && episode != Int.max ? ["s\(season)e\(episode)", String(format: "s%02de%02d", season, episode), "\(season)x\(episode)"] : []
        let local = EpisodeParser.parse(path: movie.filePath)
        let names = [movie.seriesTitle, movie.episodeInfo?.seriesTitle, local?.seriesTitle].compactMap { $0 }
        let values = [movie.title, movie.fileName] + codes
        return (values + names.flatMap { name in values.map { "\(name) \($0)" } })
            .contains { contains(normalized, in: $0) }
    }

    /// A numeric show name such as 24 must not match the tail of the year 2024.
    private static func contains(_ query: String, in value: String) -> Bool {
        let text = TitleMatcher.normalize(value)
        var remaining = text.startIndex..<text.endIndex
        while let range = text.range(of: query, range: remaining) {
            let partialLeadingNumber = query.first?.isNumber == true && range.lowerBound > text.startIndex && text[text.index(before: range.lowerBound)].isNumber
            let partialTrailingNumber = query.last?.isNumber == true && range.upperBound < text.endIndex && text[range.upperBound].isNumber
            if !partialLeadingNumber && !partialTrailingNumber { return true }
            remaining = text.index(after: range.lowerBound)..<text.endIndex
        }
        return false
    }
}
