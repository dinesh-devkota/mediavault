import CineVaultCore
import SwiftData
import SwiftUI

enum LibrarySort: String, CaseIterable, Identifiable {
    case title = "Title", recentlyAdded = "Recently Added", year = "Year", rating = "Rating", lastPlayed = "Last Played"
    var id: String { rawValue }

    func sorted(_ movies: [Movie]) -> [Movie] {
        switch self {
        case .title: return movies.sorted { $0.sortTitle < $1.sortTitle }
        case .recentlyAdded: return movies.sorted { $0.dateAdded > $1.dateAdded }
        case .year: return movies.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating: return movies.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case .lastPlayed: return movies.sorted { ($0.householdLastPlayed ?? .distantPast) > ($1.householdLastPlayed ?? .distantPast) }
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All", unwatched = "Unwatched", inProgress = "In Progress", watched = "Watched", hidden = "Hidden", watchlist = "Watchlist"
    var id: String { rawValue }

    func matches(_ movie: Movie) -> Bool {
        switch self {
        case .all: return !movie.isHidden
        case .unwatched: return !movie.isHidden && !movie.householdWatched
        case .inProgress: return !movie.isHidden && movie.isInProgress
        case .watched: return !movie.isHidden && movie.householdWatched
        case .hidden: return movie.isHidden
        case .watchlist: return !movie.isHidden && movie.householdWatchlisted
        }
    }
}

enum LibraryQuery {
    static func visible(_ movies: [Movie], sort: LibrarySort, filter: LibraryFilter,
                        genres: Set<String> = [], sourceIDs: Set<UUID> = [], decades: Set<Int> = []) -> [Movie] {
        sort.sorted(movies.filter { movie in
            HouseholdStore.shared.allows(movie) && !movie.isMissing && filter.matches(movie)
                && (genres.isEmpty || !genres.isDisjoint(with: movie.genres))
                && (sourceIDs.isEmpty || movie.source.map { sourceIDs.contains($0.id) } == true)
                && (decades.isEmpty || movie.year.map { decades.contains($0 / 10 * 10) } == true)
        })
    }

    static func watchlist(_ movies: [Movie]) -> [Movie] {
        visible(movies.filter { $0.mediaKind != .photo }, sort: .title, filter: .watchlist)
    }

}

@MainActor
final class LibraryPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var section: MediaKind { didSet { defaults.set(section.rawValue, forKey: "librarySection") } }
    @Published var sort: LibrarySort { didSet { defaults.set(sort.rawValue, forKey: "librarySort") } }
    @Published var filter: LibraryFilter { didSet { defaults.set(filter.rawValue, forKey: "libraryFilter") } }
    @Published var genres: Set<String> { didSet { defaults.set(genres.sorted(), forKey: "libraryGenres") } }
    @Published var sourceIDs: Set<UUID> { didSet { defaults.set(sourceIDs.map(\.uuidString).sorted(), forKey: "librarySourceIDs") } }
    @Published var decades: Set<Int> { didSet { defaults.set(decades.sorted(), forKey: "libraryDecades") } }

    init(defaults suppliedDefaults: UserDefaults? = nil) {
        let defaults = suppliedDefaults ?? HouseholdStore.shared.preferenceDefaults
        self.defaults = defaults
        let savedSection = defaults.string(forKey: "librarySection").flatMap(MediaKind.init(rawValue:)) ?? .movie
        section = savedSection == .photo ? .movie : savedSection
        sort = defaults.string(forKey: "librarySort").flatMap(LibrarySort.init(rawValue:)) ?? .title
        filter = defaults.string(forKey: "libraryFilter").flatMap(LibraryFilter.init(rawValue:)) ?? .all
        // An explicitly saved empty collection means All, even if an older single value exists.
        let savedGenres = defaults.stringArray(forKey: "libraryGenres") ?? [defaults.string(forKey: "libraryGenre") ?? ""]
        genres = Set(savedGenres.filter { !$0.isEmpty })
        let savedSources = defaults.stringArray(forKey: "librarySourceIDs") ?? [defaults.string(forKey: "librarySourceID") ?? ""]
        sourceIDs = Set(savedSources.compactMap(UUID.init(uuidString:)))
        let savedDecades = defaults.array(forKey: "libraryDecades") as? [Int] ?? [defaults.integer(forKey: "libraryDecade")]
        decades = Set(savedDecades.filter { $0 > 0 && $0 % 10 == 0 })
    }

    func sourcesChanged(from previousIDs: [UUID], to sources: [MediaSource]) {
        let removed = Set(previousIDs).subtracting(sources.map(\.id))
        if !sourceIDs.isDisjoint(with: removed) {
            sourceIDs.subtract(removed)
        }
    }

    func clearFilters() {
        filter = .all
        genres.removeAll()
        sourceIDs.removeAll()
        decades.removeAll()
    }
}

struct LibraryView: View {
    var openSources: () -> Void = {}
    private enum Control: String, Hashable { case sort = "Sort", show = "Show", genre = "Genre", source = "Source", decade = "Decade", section = "Section" }
    @State private var control = Control.sort
    @State private var presentingChoices = false
    @FocusState private var focusedControl: Control?
    @Query private var movies: [Movie]
    @Query(sort: \MediaSource.name) private var allSources: [MediaSource]
    private var sources: [MediaSource] {
        allSources.filter { source in
            HouseholdStore.shared.isAdmin || HouseholdStore.shared.current?.allowedFolders.contains { $0.sourceID == source.id } == true
        }
    }
    @StateObject private var preferences = LibraryPreferences()

    private var kind: MediaKind { preferences.section }

    private var filterCandidates: [Movie] {
        movies.filter { HouseholdStore.shared.allows($0) && !$0.isMissing && preferences.filter.matches($0) && $0.mediaKind == kind }
    }

    private var genres: [String] {
        var values = Set(filterCandidates.flatMap(\.genres).filter { !$0.isEmpty })
        values.formUnion(preferences.genres)
        return values.sorted()
    }

    private var decades: [Int] {
        var values = Set(filterCandidates.compactMap(\.year)
            .filter { $0 > 0 }.map { $0 / 10 * 10 })
        values.formUnion(preferences.decades)
        return values.sorted(by: >)
    }

    private var selectedSourceIDs: Set<UUID> {
        preferences.sourceIDs.intersection(sources.map(\.id))
    }

    private var visible: [Movie] {
        LibraryQuery.visible(movies.filter { $0.mediaKind == kind }, sort: preferences.sort, filter: preferences.filter,
                             genres: preferences.genres, sourceIDs: selectedSourceIDs, decades: preferences.decades)
    }

    private var hasFilters: Bool {
        preferences.filter != .all || !preferences.genres.isEmpty || !selectedSourceIDs.isEmpty || !preferences.decades.isEmpty
    }

    var body: some View {
        let results = visible
        let resultKind = kind == .tvShow ? "episode" : "title"
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR COLLECTION")
                            .font(.system(size: 18, weight: .semibold))
                            .tracking(3)
                            .foregroundStyle(CinemaTheme.accent)
                        Text(kind.label).font(.system(size: 62, weight: .bold))
                    }
                    Spacer()
                    Button("Clear filters") { preferences.clearFilters() }
                        .disabled(!hasFilters)
                    Text("\(results.count) \(resultKind)\(results.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(CinemaTheme.secondaryText)
                }

                HStack(spacing: 24) {
                    filterButton(.sort, value: preferences.sort.rawValue)
                    filterButton(.show, value: preferences.filter.rawValue)
                    filterButton(.genre, value: selectionLabel(preferences.genres.sorted(), all: "All Genres"))
                }

                HStack(spacing: 24) {
                    filterButton(.source, value: selectionLabel(sources.filter { preferences.sourceIDs.contains($0.id) }.map(\.name), all: "All Sources"))
                    filterButton(.decade, value: selectionLabel(preferences.decades.sorted().map { "\($0)s" }, all: "All Decades"))
                    filterButton(.section, value: kind.label)
                }

                BulkWatchControl(title: "Select", scope: "\(kind.label) · current results", movies: results,
                                 startsSelected: false, groupShows: true, includeHidden: preferences.filter == .hidden)

                if results.isEmpty {
                    ContentUnavailableView {
                        Label(hasFilters ? (preferences.filter == .watchlist ? "No Watchlist titles here" : "No matching titles") : "No \(kind.label.lowercased()) yet",
                              systemImage: hasFilters ? "line.3.horizontal.decrease.circle" : "folder")
                    } description: {
                        Text(hasFilters ? (preferences.filter == .watchlist ? "Open a title and choose Add to Watchlist. Clear filters to browse your collection." : "Clear filters to see all titles in this section.") : "Add the parent media folder in Sources. Its subfolders are scanned automatically.")
                    } actions: {
                        if hasFilters {
                            Button("Clear filters") {
                                preferences.clearFilters()
                                focusedControl = .show
                            }.accessibilityIdentifier("library-empty-clear")
                        } else {
                            Button("Open Sources", action: openSources)
                                .accessibilityIdentifier("library-empty-sources")
                        }
                    }
                        .padding(.top, 100)
                } else if kind == .tvShow {
                    TVShowBrowserView(episodes: results, scrollToFocus: { proxy.scrollTo($0, anchor: .center) })
                } else {
                    PosterGrid(movies: results)
                }
            }
            .padding(.horizontal, 70)
            .padding(.bottom, 100)
        }
        }
        .background(CinemaBackground())
        .sheet(isPresented: $presentingChoices, onDismiss: { focusedControl = control }) { choiceSheet }
        .onChange(of: kind) { _, _ in
            preferences.genres.removeAll(); preferences.decades.removeAll(); preferences.filter = .all
        }
        .onChange(of: sources.map(\.id)) { previousIDs, _ in
            preferences.sourcesChanged(from: previousIDs, to: sources)
        }
    }

    private func selectionLabel(_ values: [String], all: String) -> String {
        if values.count > 1 { return "\(values.count) selected" }
        return values.first ?? all
    }

    private func filterButton(_ item: Control, value: String) -> some View {
        Button {
            control = item
            presentingChoices = true
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(item.rawValue).font(.caption)
                    Text(value).font(.headline).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.down").accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focused($focusedControl, equals: item)
        .accessibilityLabel(item.rawValue)
        .accessibilityValue(value)
    }

    @ViewBuilder private var choiceSheet: some View {
        switch control {
        case .sort:
            LibraryChoiceSheet(title: "Sort", options: LibrarySort.allCases, selection: [preferences.sort], label: { $0.rawValue }) {
                if let value = $0.first { preferences.sort = value }
            }
        case .show:
            LibraryChoiceSheet(title: "Show", options: LibraryFilter.allCases, selection: [preferences.filter], label: { $0.rawValue }) {
                if let value = $0.first { preferences.filter = value }
            }
        case .section:
            LibraryChoiceSheet(title: "Section", options: MediaKind.allCases.filter { $0 != .photo }, selection: [kind], label: { $0.label }) {
                if let value = $0.first { preferences.section = value }
            }
        case .genre:
            LibraryChoiceSheet(title: "Genre", options: genres, selection: preferences.genres, all: "All Genres", label: { $0 }) {
                preferences.genres = $0
            }
        case .source:
            let names = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.name) })
            LibraryChoiceSheet(title: "Source", options: sources.map(\.id), selection: selectedSourceIDs, all: "All Sources", label: { names[$0] ?? "" }) {
                preferences.sourceIDs = $0.intersection(sources.map(\.id))
            }
        case .decade:
            LibraryChoiceSheet(title: "Decade", options: decades, selection: preferences.decades, all: "All Decades", label: { "\($0)s" }) {
                preferences.decades = $0
            }
        }
    }
}

#if DEBUG
extension LibraryView {
    init(previewingBulk: Bool) {
        self.init()
        let suite = "com.dineshdevkota.cinevault.preview.bulk"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Preview defaults unavailable") }
        defaults.removePersistentDomain(forName: suite)
        _preferences = StateObject(wrappedValue: LibraryPreferences(defaults: defaults))
    }

    init(previewingGenres preferences: LibraryPreferences) {
        self.init()
        _preferences = StateObject(wrappedValue: preferences)
        _control = State(initialValue: .genre)
        _presentingChoices = State(initialValue: true)
    }
}
#endif

struct HomeView: View {
    let openPhotos: () -> Void
    let openSources: () -> Void
    @Query(sort: \Movie.dateAdded, order: .reverse) private var movies: [Movie]
    @Query private var sources: [MediaSource]
    @State private var addingSource = false
    @EnvironmentObject private var collectionNavigation: HomeCollectionNavigation
    @EnvironmentObject private var scanner: LibraryScanner

    init(openPhotos: @escaping () -> Void, openSources: @escaping () -> Void) {
        self.openPhotos = openPhotos
        self.openSources = openSources
    }

    private var available: [Movie] { HomeCollection.available(movies) }
    private var featured: Movie? {
        let unwatched = available.filter { !$0.isInProgress && !$0.householdWatched && $0.mediaKind != .music }
        return unwatched.first { $0.backdropPath != nil } ?? unwatched.first ?? available.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                HStack(alignment: .bottom) {
                    Text("Welcome to MediaVault")
                        .font(.system(size: 54, weight: .bold))
                    Spacer()
                    if HouseholdStore.shared.configured {
                        Button(HouseholdStore.shared.current?.name ?? "Switch profile") { HouseholdStore.shared.lock() }
                            .accessibilityIdentifier("household-switch")
                    }
                    if HouseholdStore.shared.isAdmin, let status = scanner.status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(CinemaTheme.secondaryText)
                            .lineLimit(1)
                    }
                }

                if available.isEmpty {
                    if movies.contains(where: PhotoLibrary.isAvailable) {
                        homePrompt("Your photo albums are ready", symbol: "photo.on.rectangle",
                                   detail: "Browse your photos by folder.", button: "Browse Photos", action: openPhotos)
                    } else if !HouseholdStore.shared.isAdmin {
                        homePrompt("No media available for this profile yet", symbol: "person.crop.circle.badge.checkmark",
                                   detail: "Ask an Admin to allow folders or adjust your ratings. Unknown ratings remain hidden when a limit is set.",
                                   button: "Switch profile") { HouseholdStore.shared.lock() }
                    } else if sources.isEmpty {
                        homePrompt("Connect your first shared folder", symbol: "externaldrive.connected.to.line.below",
                                   detail: "Choose a folder on your NAS to add movies, shows, music and photos.",
                                   button: "Find my NAS") { addingSource = true }
                    } else if scanner.isScanning {
                        homePrompt("Scanning your folders", symbol: "arrow.clockwise",
                                   detail: "Your media will appear as the scan finds it.", button: "Open Sources", action: openSources)
                    } else {
                        homePrompt("No media in your library yet", symbol: "folder",
                                   detail: "Open Sources to check your folders or scan again.", button: "Open Sources", action: openSources)
                    }
                } else {
                    ContinueWatchingRow()
                    CollectionPosterRow(title: "Watchlist", movies: HomeCollection.watchlist.movies(in: movies), collection: .watchlist)
                    if let featured {
                        FeaturedMovieCard(movie: featured)
                    }
                    ForEach(MediaKind.allCases, id: \.self) { kind in
                        let collection = available.filter { $0.mediaKind == kind }
                        if !collection.isEmpty {
                            if kind == .tvShow { TVShowRow(episodes: collection, collection: .section(kind)) }
                            else { PosterRow(title: kind.label, movies: Array(collection.prefix(20)), collection: .section(kind)) }
                        }
                    }
                    CollectionPosterRow(title: "Unwatched", movies: available.filter { !$0.householdWatched }, collection: .unwatched)
                }
            }
            .padding(.horizontal, 70)
            .padding(.bottom, 100)
        }
        .background(CinemaBackground())
        .sheet(isPresented: $addingSource) { NASSetupView() }
        .navigationDestination(for: HomeCollection.self) { collection in
            HomeCollectionView(collection: collection)
        }
        .onChange(of: collectionNavigation.path.count) { _, count in
            guard count == 0, let origin = collectionNavigation.consumeReturnOrigin() else { return }
            var collections: [HomeCollection] = []
            if !ContinueWatching.home(movies, limit: 1).isEmpty { collections.append(.continueWatching) }
            if !HomeCollection.watchlist.movies(in: movies).isEmpty { collections.append(.watchlist) }
            collections += MediaKind.allCases.filter { kind in available.contains { $0.mediaKind == kind } }.map(HomeCollection.section)
            if available.contains(where: { !$0.householdWatched }) { collections.append(.unwatched) }
            collectionNavigation.focusRequest = collections.contains(origin) ? origin : collections.first
        }
    }

    private func homePrompt(_ title: String, symbol: String, detail: String, button: String,
                            action: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        } actions: {
            Button(button, action: action).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 68)
    }
}

@MainActor
struct SearchView: View {
    @State private var text = ""

    var body: some View {
        LibrarySearchResultsView(text: text)
            .searchable(text: $text, prompt: "Titles, shows, episodes, genres, files")
    }
}

struct LibrarySearchResultsView: View {
    let text: String
    @Query private var movies: [Movie]

    var body: some View {
        SearchResultsView(text: text, found: LibrarySearch.results(in: movies, text: text))
            .navigationDestination(for: SearchShowSelection.self) { selection in
                SearchShowDestination(selection: selection)
            }
    }
}

private struct SearchResultsView: View {
    let text: String
    let found: LibrarySearchResults
    @State private var lastFocusedResult: String?
    @State private var focusedMovieAnchor: UUID?
    @FocusState private var focusedResult: String?
    private let posterColumns = [GridItem(.adaptive(minimum: CinemaTheme.posterWidth, maximum: CinemaTheme.posterWidth), spacing: 48)]
    private let episodeColumns = [GridItem(.adaptive(minimum: 400, maximum: 400), spacing: 48)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Text("Search").font(.system(size: 62, weight: .bold)).id("search-top")
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView("Search your collection", systemImage: "magnifyingglass",
                            description: Text("Find movies, shows, episodes, music and photos."))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 100)
                    } else if found.isEmpty {
                        ContentUnavailableView("No results", systemImage: "magnifyingglass",
                            description: Text("Try a show name, episode title, genre or file name."))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 100)
                    } else {
                        Text("\(found.count) \(found.count == 1 ? "result" : "results")").foregroundStyle(CinemaTheme.secondaryText)
                        if !found.shows.isEmpty {
                            Text("TV Shows").font(.title2)
                            showGrid(found.shows)
                        }
                        if !found.episodes.isEmpty {
                            Text("Episodes").font(.title2)
                            episodeGrid(found.episodes)
                        }
                        if !found.titles.isEmpty {
                            if !found.shows.isEmpty || !found.episodes.isEmpty || !found.photos.isEmpty { Text("Movies & Music").font(.title2) }
                            titleGrid(found.titles)
                        }
                        if !found.photos.isEmpty {
                            Text("Photos").font(.title2)
                            PhotoGrid(photos: found.photos, showsSourceName: true, onSelection: { _ in
                                lastFocusedResult = nil; focusedMovieAnchor = nil
                            }, scrollToPhoto: { proxy.scrollTo($0, anchor: .center) })
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 70).padding(.bottom, 100)
            }
            .frame(maxWidth: .infinity)
            .task {
                let selected = lastFocusedResult.flatMap { found.focusIDs.contains($0) ? $0 : nil }
                    ?? focusedMovieAnchor.flatMap { found.focusID(containing: $0) }
                guard let selected else { return }
                await Task.yield()
                guard !Task.isCancelled, lastFocusedResult != nil else { return }
                proxy.scrollTo(selected, anchor: .center)
                await Task.yield()
                guard !Task.isCancelled, lastFocusedResult != nil else { return }
                focusedResult = selected
            }
            .onChange(of: text) { _, _ in
                lastFocusedResult = nil; focusedMovieAnchor = nil; focusedResult = nil
                proxy.scrollTo("search-top", anchor: .top)
            }
            .onChange(of: focusedResult) { _, value in
                if let value {
                    lastFocusedResult = value
                    focusedMovieAnchor = found.movieID(forFocusID: value)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CinemaBackground())
    }

    private func showGrid(_ shows: [ShowSearchResult]) -> some View {
        LazyVGrid(columns: posterColumns, spacing: 55) {
            ForEach(shows) { result in
                let key = "show:\(result.id)"
                NavigationLink(value: SearchShowSelection(result.show)) {
                    TVShowArtwork(title: result.show.title, subtitle: result.subtitle,
                        path: result.show.posterPath, embyMovie: result.show.firstEpisode, embySeries: true, focused: focusedResult == key)
                }.buttonStyle(ArtworkButtonStyle()).focusEffectDisabled().focused($focusedResult, equals: key).id(key)
            }
        }.padding(.vertical, 24)
    }

    private func episodeGrid(_ episodes: [SearchEpisodeResult]) -> some View {
        LazyVGrid(columns: episodeColumns, spacing: 48) {
            ForEach(episodes) { result in
                let key = "episode:\(result.id)"
                NavigationLink(value: result.movie) {
                    TVShowArtwork(title: result.movie.title, subtitle: result.subtitle,
                        path: result.movie.backdropPath, embyMovie: result.movie, wide: true, focused: focusedResult == key)
                }.buttonStyle(ArtworkButtonStyle()).focusEffectDisabled().focused($focusedResult, equals: key).id(key)
            }
        }.padding(.vertical, 24)
    }

    private func titleGrid(_ movies: [Movie]) -> some View {
        LazyVGrid(columns: posterColumns, spacing: 55) {
            ForEach(movies) { movie in
                let key = "title:\(movie.id)"
                NavigationLink(value: movie) { PosterView(movie: movie, isFocused: focusedResult == key) }
                    .buttonStyle(ArtworkButtonStyle()).focusEffectDisabled().focused($focusedResult, equals: key).id(key)
            }
        }.padding(.vertical, 24)
    }
}

private struct SearchShowDestination: View {
    let selection: SearchShowSelection
    @Query private var movies: [Movie]
    @State private var currentShowID: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let show = selection.resolve(in: movies, currentShowID: currentShowID)
        Group {
            if let show {
                TVShowDestination(episodes: show.episodes, initialShowID: show.id)
            } else {
                Color.clear.task { dismiss() }
            }
        }
        .onChange(of: show?.id, initial: true) { _, id in currentShowID = id }
    }
}

struct PosterGrid: View {
    let movies: [Movie]
    @FocusState private var focusedMovie: UUID?
    private let columns = [GridItem(.adaptive(minimum: CinemaTheme.posterWidth, maximum: CinemaTheme.posterWidth), spacing: 48)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 55) {
            ForEach(movies) { movie in
                NavigationLink(value: movie) {
                    PosterView(movie: movie, isFocused: focusedMovie == movie.id)
                }
                .buttonStyle(ArtworkButtonStyle())
                .focusEffectDisabled()
                .focused($focusedMovie, equals: movie.id)
            }
        }
        .padding(.vertical, 24)
    }
}

struct PosterRow: View {
    let title: String
    let movies: [Movie]
    var collection: HomeCollection? = nil
    @FocusState private var focusedMovie: UUID?

    var body: some View {
        if !movies.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HomeShelfHeader(title: title, collection: collection)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 42) {
                        ForEach(movies) { movie in
                            NavigationLink(value: movie) {
                                PosterView(movie: movie, isFocused: focusedMovie == movie.id)
                            }
                            .buttonStyle(ArtworkButtonStyle())
                            .focusEffectDisabled()
                            .focused($focusedMovie, equals: movie.id)
                        }
                    }
                    .padding(.vertical, 24)
                }
                .scrollClipDisabled()
            }
        }
    }
}

struct FeaturedMovieCard: View {
    let movie: Movie

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                MovieBackdrop(movie: movie)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.95), location: 0),
                        .init(color: .black.opacity(0.75), location: 0.35),
                        .init(color: .black.opacity(0.10), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(colors: [.clear, .black.opacity(0.5)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 18) {
                    Text("FEATURED MOVIE")
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(3)
                        .foregroundStyle(CinemaTheme.accent)
                    Text(movie.title)
                        .font(.system(size: 52, weight: .bold))
                        .lineLimit(2)
                    Text(MoviePresentation.metadata(for: movie))
                        .font(.callout)
                        .foregroundStyle(CinemaTheme.secondaryText)
                    if let overview = movie.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                    }
                    NavigationLink(value: movie) {
                        Label("View Movie", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .padding(.top, 8)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(48)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
        }
        .frame(height: 500)
    }
}

struct ContinueWatchingRow: View {
    @Query private var library: [Movie]

    var body: some View {
        ContinueWatchingCards(suggestions: ContinueWatching.home(library))
    }
}

private struct ContinueWatchingCards: View {
    let suggestions: [WatchSuggestion]
    @FocusState private var focusedItem: String?

    var body: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HomeShelfHeader(title: "Continue Watching", collection: .continueWatching)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 36) {
                        ForEach(suggestions) { item in
                            NavigationLink(value: item.movie) {
                                ContinueWatchingCard(item: item, isFocused: focusedItem == item.id)
                            }
                            .buttonStyle(ArtworkButtonStyle())
                            .focusEffectDisabled()
                            .focused($focusedItem, equals: item.id)
                            .accessibilityLabel("\(item.title), \(item.subtitle)")
                            .accessibilityIdentifier("continue-watching-\(item.id)")
                        }
                    }
                    .padding(.vertical, 24)
                }
                .scrollClipDisabled()
            }
        }
    }
}

struct ContinueWatchingCard: View {
    let item: WatchSuggestion
    let isFocused: Bool
    private let width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MovieBackdrop(movie: item.movie, usePosterFallback: true)
                .frame(width: width, height: 225)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 90)
                }
                .overlay(alignment: .bottom) {
                    if item.movie.isInProgress && item.movie.duration > 0 {
                        ProgressView(value: item.movie.progress)
                            .tint(CinemaTheme.accent)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(isFocused ? 0.9 : 0.10), lineWidth: isFocused ? 3 : 1)
                }
            Text(item.title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(item.subtitle)
                .font(.system(size: 20))
                .foregroundStyle(CinemaTheme.secondaryText)
        }
        .frame(width: width, alignment: .leading)
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

struct PosterView: View {
    let movie: Movie
    var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                ArtworkFallback(title: movie.title)
                VStack(spacing: 18) {
                    Image(systemName: "film")
                        .font(.system(size: 55, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(movie.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 18)
                }
                if movie.source?.isEmby == true {
                    EmbyArtwork(movie: movie, width: 342)
                } else {
                    AsyncImage(url: TMDB.imageURL(movie.posterPath, size: "w342")) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Color.clear }
                }
            }
            .frame(width: CinemaTheme.posterWidth, height: CinemaTheme.posterHeight)
            .clipped()
            .overlay(alignment: .bottom) {
                if movie.isInProgress {
                    ProgressView(value: movie.progress)
                        .tint(CinemaTheme.accent)
                        .padding(10)
                        .background(.black.opacity(0.45))
                }
            }
            .overlay(alignment: .topTrailing) {
                if movie.householdWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(isFocused ? 0.9 : 0.10), lineWidth: isFocused ? 3 : 1)
            }
            .shadow(color: .black.opacity(isFocused ? 0.6 : 0.25), radius: isFocused ? 20 : 8, y: 10)

            Text(movie.title)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(movie.displayYear.isEmpty ? "Movie" : movie.displayYear)
                .font(.system(size: 19))
                .foregroundStyle(CinemaTheme.secondaryText)
        }
        .frame(width: CinemaTheme.posterWidth, alignment: .leading)
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}
