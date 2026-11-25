import CineVaultCore
import SwiftData
import SwiftUI

struct TVShowGroup: Identifiable {
    let id: String
    let title: String
    let episodes: [Movie]
    struct Revision: Equatable {
        let id: UUID
        let path: String
        let title: String?
        let tmdbID: Int?
        let year: Int?
        let season: Int?
        let episode: Int?
    }
    static func revision(_ movie: Movie) -> Revision {
        Revision(id: movie.id, path: movie.filePath, title: movie.seriesTitle,
                 tmdbID: movie.seriesTMDBID, year: movie.year,
                 season: movie.seasonNumber, episode: movie.episodeNumber)
    }
    var posterPath: String? { episodes.compactMap(\.posterPath).first }
    var seasons: [Int] {
        Set(episodes.map(Self.season)).sorted {
            if $0 == -1 { return false }
            if $1 == -1 { return true }
            return $0 < $1
        }
    }
    static func season(_ movie: Movie) -> Int { movie.seasonNumber ?? movie.episodeInfo?.season ?? -1 }
    static func episode(_ movie: Movie) -> Int { movie.episodeNumber ?? movie.episodeInfo?.episode ?? Int.max }
    static func seasonTitle(_ value: Int) -> String {
        value == 0 ? "Specials" : value < 0 ? "Other episodes" : "Season \(value)"
    }
    func episodes(in season: Int) -> [Movie] {
        episodes.filter { Self.season($0) == season }.sorted {
            let left = Self.episode($0), right = Self.episode($1)
            if left != right { return left < right }
            if $0.filePath != $1.filePath { return $0.filePath < $1.filePath }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var firstEpisode: Movie? {
        guard let season = seasons.first else { return nil }
        return episodes(in: season).first
    }

    /// The caller owns filtering and ordering, including the Hidden and Watchlist views.
    static func groups(_ episodes: [Movie]) -> [TVShowGroup] {
        func aliases(_ movie: Movie) -> [String] {
            return [movie.episodeInfo, EpisodeParser.parse(path: movie.filePath)].compactMap { $0 }
                .filter { !$0.seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
                    $0.seriesTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                        .split(whereSeparator: \.isWhitespace).joined(separator: " ") + "|" + ($0.year.map(String.init) ?? "unknown")
                }
        }
        let prepared = episodes.filter { HouseholdStore.shared.allows($0) }.map { ($0, aliases($0)) }
        var known: [String: Set<Int>] = [:]
        for (movie, keys) in prepared {
            if let id = movie.seriesTMDBID {
                for alias in keys { known[alias, default: []].insert(id) }
            }
        }
        var order: [String] = []
        var grouped: [String: [Movie]] = [:]
        for (movie, keys) in prepared {
            let candidates = Set(keys.flatMap { Array(known[$0] ?? []) })
            let id = movie.seriesTMDBID ?? (candidates.count == 1 ? candidates.first : nil)
            let key = id.map { "tmdb:\($0)" } ?? keys.first.map { "title:\($0)" } ?? "file:\(movie.id)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(movie)
        }
        return order.map { key in
            let items = grouped[key] ?? []
            let title = items.compactMap(\.seriesTitle).first(where: { !$0.isEmpty })
                ?? items.compactMap { $0.episodeInfo?.seriesTitle }.first ?? "Unidentified show"
            return TVShowGroup(id: key, title: title, episodes: items)
        }
    }
}

/// Normal collection rows contain one tile per show; playback rows keep individual episodes.
enum CollectionRowItem: Identifiable {
    case movie(Movie)
    case show(TVShowGroup)

    var id: String {
        switch self {
        case .movie(let movie): return "movie:\(movie.id)"
        case .show(let show): return "show:\(show.id)"
        }
    }

    /// Group the full filtered collection before limiting tiles, preserving its first-occurrence order.
    static func grouped(_ movies: [Movie], limit: Int = 20, groupVersions: Bool = false) -> [CollectionRowItem] {
        guard limit > 0 else { return [] }
        let shows = TVShowGroup.groups(movies.filter { $0.mediaKind == .tvShow })
        var showByEpisode: [UUID: TVShowGroup] = [:]
        for show in shows {
            for episode in show.episodes { showByEpisode[episode.id] = show }
        }
        var seen: Set<String> = []
        var result: [CollectionRowItem] = []
        for movie in movies {
            let item = showByEpisode[movie.id].map(CollectionRowItem.show) ?? .movie(movie)
            let groupingKey = groupVersions && movie.mediaKind != .tvShow ? MovieVersions.key(movie) : item.id
            guard seen.insert(groupingKey).inserted else { continue }
            result.append(item)
            if result.count == limit { break }
        }
        return result
    }
}

struct TVShowBrowserView: View {
    let episodes: [Movie]
    var initialShowID: String? = nil
    var scrollToFocus: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var selectedShowID: String?
    @State private var selectedSeason: Int?
    @State private var selectedEpisodeID: UUID?
    @State private var lastFocusedSeason: Int?
    @State private var focusRequestID = UUID()
    @State private var initialized = false
    @State private var shows: [TVShowGroup] = []
    @FocusState private var focusedItem: String?
    @Query private var library: [Movie]

    private var selectedShow: TVShowGroup? {
        shows.first { $0.id == selectedShowID }
            ?? shows.first { show in selectedEpisodeID.map { id in show.episodes.contains { $0.id == id } } ?? false }
            ?? shows.first { $0.id == initialShowID }
    }
    private var posterColumns: [GridItem] {
        [GridItem(.adaptive(minimum: CinemaTheme.posterWidth, maximum: CinemaTheme.posterWidth), spacing: CinemaTheme.gridSpacing)]
    }

    var body: some View {
        Group {
            if selectedShowID == nil { content }
            else { content.onTVExit { goBack() } }
        }
        .onAppear {
            if !initialized {
                initialized = true
                shows = TVShowGroup.groups(episodes)
                selectedShowID = initialShowID
                selectedEpisodeID = shows.first { $0.id == initialShowID }?.firstEpisode?.id
            }
            restoreSelectionFocus()
        }
        .onDisappear { focusRequestID = UUID() }
        .onChange(of: focusedItem) { _, value in
            if let value, let id = UUID(uuidString: value), selectedShow?.episodes.contains(where: { $0.id == id }) == true {
                selectedEpisodeID = id
            }
        }
        .onChange(of: episodes.map(TVShowGroup.revision)) { _, _ in
            shows = TVShowGroup.groups(episodes)
            if let season = selectedSeason, let items = selectedShow?.episodes(in: season),
               !items.isEmpty && !items.contains(where: { $0.id == selectedEpisodeID }) {
                restoreSelectionFocus()
            }
        }
        .onChange(of: shows.map(\.id)) { _, _ in
            if let show = selectedShow { selectedShowID = show.id; restoreSelectionFocus() }
            else { selectedShowID = nil; selectedSeason = nil; selectedEpisodeID = nil }
        }
        .onChange(of: selectedShow?.seasons) { _, values in
            if let selectedSeason, values?.contains(selectedSeason) != true {
                self.selectedSeason = nil; restoreSelectionFocus()
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            if selectedShowID != nil || initialShowID != nil {
                HStack(spacing: 28) {
                    Button("Back") { goBack() }
                    if let show = selectedShow {
                        Text(selectedSeason.map { "\(show.title) · \(TVShowGroup.seasonTitle($0))" } ?? show.title)
                            .font(.system(size: 32, weight: .semibold))
                    }
                }
            }
            if let show = selectedShow {
                // Home and filtered library shelves may pass only some of a show's episodes.
                // Resolve its full current library before offering a show or season action.
                let currentShow = SearchShowSelection(show).resolve(in: library) ?? show
                let currentEpisodes = selectedSeason.map { currentShow.episodes(in: $0) } ?? currentShow.episodes
                let scope = selectedSeason.map { "\(currentShow.title) · \(TVShowGroup.seasonTitle($0))" } ?? "\(currentShow.title) · all seasons"
                BulkWatchControl(title: "Watched status", scope: scope, movies: currentEpisodes)
            }
            if let show = selectedShow, let season = selectedSeason {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: CinemaTheme.episodeWidth, maximum: CinemaTheme.episodeWidth), spacing: CinemaTheme.gridSpacing)], spacing: 48) {
                    ForEach(show.episodes(in: season)) { episode in
                        let key = episode.id.uuidString
                        let number = TVShowGroup.episode(episode)
                        NavigationLink(value: episode) {
                            TVShowArtwork(title: number == Int.max ? episode.title : "E\(number) · \(episode.title)",
                                subtitle: episode.householdWatched ? "Watched" : episode.isInProgress ? "In progress" : "Episode",
                                path: episode.backdropPath, localMovie: episode, localPath: episode.localBackdropPath, wide: true, focused: focusedItem == key)
                        }
                        .buttonStyle(ArtworkButtonStyle()).focusEffectDisabled().focused($focusedItem, equals: key).id(key)
                    }
                }
            } else if let show = selectedShow {
                LazyVGrid(columns: posterColumns, spacing: 55) {
                    ForEach(show.seasons, id: \.self) { season in
                        let items = show.episodes(in: season)
                        let key = "season:\(season)"
                        Button { selectedSeason = season; lastFocusedSeason = season; restoreSelectionFocus() } label: {
                            TVShowArtwork(title: TVShowGroup.seasonTitle(season), subtitle: "\(items.count) \(items.count == 1 ? "episode" : "episodes")",
                                path: items.compactMap(\.seasonPosterPath).first,
                                localMovie: items.first(where: { $0.localSeasonPosterPath != nil }),
                                localPath: items.compactMap(\.localSeasonPosterPath).first, focused: focusedItem == key)
                        }
                        .buttonStyle(ArtworkButtonStyle()).focusEffectDisabled().focused($focusedItem, equals: key).id(key)
                    }
                }
            } else {
                LazyVGrid(columns: posterColumns, spacing: 55) {
                    ForEach(shows) { show in
                        Button {
                            selectedShowID = show.id
                            selectedEpisodeID = show.firstEpisode?.id
                            selectedSeason = nil; lastFocusedSeason = nil
                            restoreSelectionFocus()
                        } label: {
                            TVShowArtwork(title: show.title, subtitle: "\(show.seasons.count) seasons",
                                path: show.posterPath, localMovie: show.episodes.first(where: { $0.localPosterPath != nil }),
                                localPath: show.episodes.compactMap(\.localPosterPath).first, focused: focusedItem == show.id)
                        }
                        .buttonStyle(ArtworkButtonStyle()).focusEffectDisabled().focused($focusedItem, equals: show.id).id(show.id)
                    }
                }
            }
        }
        .padding(.vertical, 24)
    }

    private func goBack() {
        if let season = selectedSeason {
            selectedSeason = nil; lastFocusedSeason = season
            restoreSelectionFocus()
        }
        else if initialShowID != nil { dismiss() }
        else {
            let showID = selectedShow?.id ?? selectedShowID
            selectedShowID = nil; selectedEpisodeID = nil; lastFocusedSeason = nil
            focusAfterPlacement(showID)
        }
    }

    private func restoreSelectionFocus() {
        guard let show = selectedShow else { return }
        if let season = selectedSeason {
            let items = show.episodes(in: season)
            let episode = selectedEpisodeID.flatMap { id in items.first { $0.id == id } } ?? items.first
            focusAfterPlacement(episode?.id.uuidString)
        } else {
            let season = lastFocusedSeason.flatMap { show.seasons.contains($0) ? $0 : nil } ?? show.seasons.first
            focusAfterPlacement(season.map { "season:\($0)" })
        }
    }

    private func focusAfterPlacement(_ item: String?) {
        let token = UUID(); focusRequestID = token
        Task { @MainActor in
            await Task.yield()
            guard focusRequestID == token else { return }
            if let item { scrollToFocus(item) }
            await Task.yield()
            guard focusRequestID == token else { return }
            focusedItem = item
        }
    }
}

struct TVShowDestination: View {
    let episodes: [Movie]
    let initialShowID: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TVShowBrowserView(episodes: episodes, initialShowID: initialShowID,
                    scrollToFocus: { proxy.scrollTo($0, anchor: .center) })
                    .padding(.horizontal, CinemaTheme.edgeInset).padding(.bottom, 100)
            }
        }.background(CinemaBackground())
    }
}

struct CollectionPosterRow: View {
    let title: String
    let movies: [Movie]
    var collection: HomeCollection? = nil
    @FocusState private var focusedItem: String?

    var body: some View {
        // Derive the shelf before deciding whether to display it. An onChange
        // attached to an initially empty Group cannot initialize its contents.
        let items = CollectionRowItem.grouped(movies, groupVersions: true)
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HomeShelfHeader(title: title, collection: collection)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 42) {
                            ForEach(items) { item in
                                switch item {
                                case .movie(let movie):
                                    VersionAwareMovieLink(movie: movie, candidates: movies, isFocused: focusedItem == item.id)
                                    .buttonStyle(ArtworkButtonStyle()).focusEffectDisabled().focused($focusedItem, equals: item.id)
                                case .show(let show):
                                    NavigationLink {
                                        TVShowDestination(episodes: show.episodes, initialShowID: show.id)
                                    } label: {
                                        TVShowArtwork(title: show.title, subtitle: "\(show.seasons.count) seasons",
                                            path: show.posterPath, localMovie: show.episodes.first(where: { $0.localPosterPath != nil }), localPath: show.episodes.compactMap(\.localPosterPath).first, focused: focusedItem == item.id)
                                    }
                                    .buttonStyle(ArtworkButtonStyle()).focusEffectDisabled().focused($focusedItem, equals: item.id)
                                }
                            }
                        }
                        .padding(.vertical, 24)
                    }
                    .scrollClipDisabled()
                }
            }
        }
    }
}

struct TVShowRow: View {
    let episodes: [Movie]
    var collection: HomeCollection? = nil
    @State private var shows: [TVShowGroup] = []
    @FocusState private var focusedShow: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HomeShelfHeader(title: "TV Shows", collection: collection)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 42) {
                    ForEach(shows) { show in
                        NavigationLink {
                            TVShowDestination(episodes: episodes, initialShowID: show.id)
                        } label: {
                            TVShowArtwork(title: show.title, subtitle: "\(show.seasons.count) seasons",
                                path: show.posterPath, localMovie: show.episodes.first(where: { $0.localPosterPath != nil }), localPath: show.episodes.compactMap(\.localPosterPath).first, focused: focusedShow == show.id)
                        }
                        .buttonStyle(ArtworkButtonStyle()).focusEffectDisabled().focused($focusedShow, equals: show.id)
                    }
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
        .onChange(of: episodes.map(TVShowGroup.revision), initial: true) { _, _ in
            shows = Array(TVShowGroup.groups(episodes).prefix(20))
        }
    }
}

struct TVShowArtwork: View {
    let title: String
    let subtitle: String
    let path: String?
    var localMovie: Movie? = nil
    var localPath: String? = nil
    var wide = false
    var focused = false
    var compact = false
    private var width: CGFloat { wide ? CinemaTheme.episodeWidth : CinemaTheme.posterWidth }
    private var height: CGFloat { wide ? CinemaTheme.episodeWidth * 9 / 16 : CinemaTheme.posterHeight }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                ArtworkFallback(title: title)
                VStack(spacing: 16) {
                    Image(systemName: wide ? "play.rectangle" : "tv").font(.system(size: 50, weight: .ultraLight))
                    Text(title).font(.headline).multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 18)
                }
                .foregroundStyle(CinemaTheme.secondaryText)
                if let localMovie, let localPath {
                    LocalArtworkView(movie: localMovie, path: localPath, wide: wide)
                } else {
                    AsyncImage(url: TMDB.imageURL(path, size: wide ? "w780" : "w342")) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Color.clear }
                }
            }
            .frame(width: width, height: height).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(focused ? 0.9 : 0.1), lineWidth: focused ? 3 : 1) }
            Text(title).font(.system(size: compact ? 15 : 23, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
            Text(subtitle).font(.system(size: compact ? 13 : 19)).foregroundStyle(CinemaTheme.secondaryText)
        }
        .frame(width: width, alignment: .leading)
        .scaleEffect(focused ? 1.04 : 1).animation(.easeOut(duration: 0.18), value: focused)
    }
}
