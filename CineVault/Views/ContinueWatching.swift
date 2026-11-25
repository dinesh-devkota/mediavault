import Foundation

struct WatchSuggestion: Identifiable {
    enum Action: String { case resume = "Resume", next = "Next episode", nextAvailable = "Next available" }
    let movie: Movie
    let showID: String?
    let showTitle: String?
    let action: Action
    let lastActivity: Date?

    var id: String { showID.map { "show:\($0)" } ?? "movie:\(movie.id)" }
    var title: String { showTitle ?? movie.title }
    var subtitle: String {
        if let info = movie.episodeInfo {
            return "\(action.rawValue) · " + String(format: "S%02dE%02d", info.season, info.episode)
        }
        return movie.displayYear.isEmpty ? action.rawValue : "\(action.rawValue) · \(movie.displayYear)"
    }
}

@MainActor
enum ContinueWatching {
    private struct EpisodeNumber: Hashable, Comparable {
        let season: Int
        let episode: Int

        init?(_ movie: Movie) {
            guard let info = movie.episodeInfo else { return nil }
            season = info.season
            episode = info.episode
        }

        static func < (left: Self, right: Self) -> Bool {
            (left.season, left.episode) < (right.season, right.episode)
        }

        func immediatelyFollows(_ previous: Self) -> Bool {
            (season == previous.season && episode == previous.episode + 1)
                || (season == previous.season + 1 && episode == 1)
        }
    }

    private static func eligible(_ movie: Movie) -> Bool {
        LibrarySearch.isAvailable(movie) && movie.source != nil && PlaybackController.isNativeCandidate(movie)
    }

    // A scan can return alternate files in any order. Use the same copy on every visit.
    private static func activityFirst(_ lhs: Movie, _ rhs: Movie) -> Bool {
        let left = lhs.householdLastPlayed ?? .distantPast, right = rhs.householdLastPlayed ?? .distantPast
        if left != right { return left > right }
        if lhs.filePath != rhs.filePath { return lhs.filePath < rhs.filePath }
        let leftSource = lhs.source?.id.uuidString ?? "", rightSource = rhs.source?.id.uuidString ?? ""
        if leftSource != rightSource { return leftSource < rightSource }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func home(_ movies: [Movie], limit: Int = 20) -> [WatchSuggestion] {
        var suggestions: [WatchSuggestion] = []
        var activeEpisodes: Set<UUID> = []
        // The first NAS scan may add thousands of episodes before anything has been played.
        for movie in movies where movie.isInProgress || (movie.householdWatched && movie.householdLastPlayed != nil) {
            guard eligible(movie) else { continue }
            switch movie.mediaKind {
            case .tvShow: activeEpisodes.insert(movie.id)
            case .movie, .documentary:
                if movie.isInProgress {
                    suggestions.append(WatchSuggestion(movie: movie, showID: nil, showTitle: nil,
                                                       action: .resume, lastActivity: movie.householdLastPlayed))
                }
            default: break
            }
        }

        if !activeEpisodes.isEmpty {
            let episodes = movies.filter { eligible($0) && $0.mediaKind == .tvShow }
            for show in TVShowGroup.groups(episodes) {
                guard let anchor = show.episodes.filter({ activeEpisodes.contains($0.id) }).min(by: activityFirst) else { continue }
                if anchor.isInProgress {
                    suggestions.append(WatchSuggestion(movie: anchor, showID: show.id, showTitle: show.title,
                                                       action: .resume, lastActivity: anchor.householdLastPlayed))
                } else if let next = successor(after: anchor, in: show) {
                    suggestions.append(next)
                }
            }
        }
        return Array(suggestions.sorted {
            let left = $0.lastActivity ?? .distantPast, right = $1.lastActivity ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }.prefix(max(0, limit)))
    }

    static func next(after movie: Movie, in movies: [Movie]) -> WatchSuggestion? {
        guard movie.episodeInfo != nil, eligible(movie) else { return nil }
        let episodes = movies.filter { eligible($0) && $0.mediaKind == .tvShow }
        guard let show = TVShowGroup.groups(episodes).first(where: { $0.episodes.contains { $0.id == movie.id } }) else { return nil }
        return successor(after: movie, in: show)
    }

    private static func successor(after anchor: Movie, in show: TVShowGroup) -> WatchSuggestion? {
        guard let current = EpisodeNumber(anchor) else { return nil }
        var copies: [EpisodeNumber: [Movie]] = [:]
        for movie in show.episodes {
            guard let number = EpisodeNumber(movie), number > current,
                  (number.season == 0) == (current.season == 0) else { continue }
            copies[number, default: []].append(movie)
        }
        for number in copies.keys.sorted() {
            guard let versions = copies[number], !versions.contains(where: { $0.householdWatched }) else { continue }
            let partial = versions.filter { $0.isInProgress }
            guard let target = (partial.isEmpty ? versions : partial).min(by: activityFirst) else { continue }
            return WatchSuggestion(movie: target, showID: show.id, showTitle: show.title,
                                   action: number.immediatelyFollows(current) ? .next : .nextAvailable,
                                   lastActivity: anchor.householdLastPlayed)
        }
        return nil
    }
}
