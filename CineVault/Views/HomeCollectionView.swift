import CineVaultCore
import SwiftData
import SwiftUI

/// Home browsing is temporary and never changes the user's saved Library filters.
enum HomeCollection: Hashable, Identifiable {
    case section(MediaKind), watchlist, unwatched, continueWatching

    var title: String {
        switch self {
        case .section(let kind): return kind.label
        case .watchlist: return "Watchlist"
        case .unwatched: return "Unwatched"
        case .continueWatching: return "Continue Watching"
        }
    }

    var id: String {
        switch self {
        case .section(let kind): return kind.rawValue
        case .watchlist: return "watchlist"
        case .unwatched: return "unwatched"
        case .continueWatching: return "continue"
        }
    }

    @MainActor
    static func available(_ movies: [Movie]) -> [Movie] {
        movies.filter { LibrarySearch.isAvailable($0) && $0.source != nil && $0.mediaKind != .photo }
            .sorted { left, right in
                if left.dateAdded != right.dateAdded { return left.dateAdded > right.dateAdded }
                return left.id.uuidString < right.id.uuidString
            }
    }

    @MainActor
    func movies(in library: [Movie]) -> [Movie] {
        let available = Self.available(library)
        switch self {
        case .section(let kind): return available.filter { $0.mediaKind == kind }
        case .watchlist: return LibrarySort.title.sorted(available.filter(\.isWatchlisted))
        case .unwatched: return available.filter { !$0.isWatched }
        case .continueWatching: return ContinueWatching.home(available, limit: .max).map(\.movie)
        }
    }

    @MainActor
    func items(in library: [Movie]) -> [CollectionRowItem] {
        CollectionRowItem.grouped(movies(in: library), limit: .max)
    }
}

@MainActor
final class HomeCollectionNavigation: ObservableObject {
    @Published var collection: HomeCollection?
    @Published var focusRequest: HomeCollection?
    var lastCollection: HomeCollection?

    func open(_ collection: HomeCollection) {
        focusRequest = nil
        lastCollection = collection
        self.collection = collection
    }
}

struct HomeShelfHeader: View {
    let title: String
    var collection: HomeCollection? = nil

    var body: some View {
        HStack {
            Text(title).font(.system(size: 32, weight: .semibold))
            Spacer()
            if let collection { HomeSeeAllButton(collection: collection) }
        }
    }
}

private struct HomeSeeAllButton: View {
    let collection: HomeCollection
    @EnvironmentObject private var navigation: HomeCollectionNavigation
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            navigation.open(collection)
        } label: {
            Label("See all", systemImage: "chevron.right")
        }
        .focused($focused)
        .accessibilityLabel("See all \(collection.title)")
        .accessibilityIdentifier("home-see-all-\(collection.id)")
        .onChange(of: navigation.focusRequest) { _, _ in restoreFocus() }
        .onAppear { restoreFocus() }
        .onChange(of: focused) { _, value in
            if value && navigation.focusRequest == collection { navigation.focusRequest = nil }
        }
    }

    private func restoreFocus() {
        guard navigation.focusRequest == collection else { return }
        Task { @MainActor in
            await Task.yield()
            guard navigation.collection == nil && navigation.focusRequest == collection else { return }
            focused = true
        }
    }
}

struct HomeCollectionView: View {
    let collection: HomeCollection
    @Query private var library: [Movie]
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedItem: String?
    @State private var lastFocusedItem: String?
    @State private var focusedMovieAnchor: UUID?
    private let columns = [GridItem(.adaptive(minimum: CinemaTheme.posterWidth, maximum: CinemaTheme.posterWidth), spacing: 48)]
    private let wideColumns = [GridItem(.adaptive(minimum: 400, maximum: 400), spacing: 48)]

    var body: some View {
        let items = collection == .continueWatching ? [] : collection.items(in: library)
        let suggestions = collection == .continueWatching ? ContinueWatching.home(library, limit: .max) : []
        let count = collection == .continueWatching ? suggestions.count : items.count
        let noun = collection == .section(.tvShow) ? "show" : "title"
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    HStack(spacing: 28) {
                        Button("Back") { dismiss() }.accessibilityIdentifier("home-collection-back")
                            .focused($focusedItem, equals: "back").id("back")
                        Text(collection.title).font(.system(size: 54, weight: .bold))
                            .accessibilityIdentifier("home-collection-title")
                        Spacer()
                        Text("\(count) \(noun)\(count == 1 ? "" : "s")")
                            .foregroundStyle(CinemaTheme.secondaryText)
                            .accessibilityIdentifier("home-collection-count")
                    }
                    if count == 0 {
                        ContentUnavailableView {
                            Label("Nothing here yet", systemImage: "rectangle.stack")
                        } description: {
                            Text(collection == .watchlist ? "Open a title and choose Add to Watchlist." : "Return Home to browse another collection.")
                        } actions: {
                            Button("Back to Home") { dismiss() }
                        }
                    } else if collection == .continueWatching {
                        LazyVGrid(columns: wideColumns, spacing: 48) {
                            ForEach(suggestions) { item in
                                NavigationLink(value: item.movie) {
                                    ContinueWatchingCard(item: item, isFocused: focusedItem == item.id)
                                }
                                .buttonStyle(ArtworkButtonStyle()).focusEffectDisabled()
                                .focused($focusedItem, equals: item.id).id(item.id)
                                .accessibilityLabel("\(item.title), \(item.subtitle)")
                                .accessibilityIdentifier("home-collection-item-\(item.id)")
                            }
                        }.padding(.vertical, 24)
                    } else {
                        LazyVGrid(columns: columns, spacing: 55) {
                            ForEach(items) { item in
                                collectionCard(item)
                                    .buttonStyle(ArtworkButtonStyle()).focusEffectDisabled()
                                    .focused($focusedItem, equals: item.id).id(item.id)
                                    .accessibilityIdentifier("home-collection-item-\(item.id)")
                            }
                        }.padding(.vertical, 24)
                    }
                }
                .padding(.horizontal, 70).padding(.bottom, 100)
            }
            .onChange(of: focusedItem) { _, value in
                if let value {
                    lastFocusedItem = value
                    if let suggestion = suggestions.first(where: { $0.id == value }) { focusedMovieAnchor = suggestion.movie.id }
                    else if let item = items.first(where: { $0.id == value }) {
                        switch item {
                        case .movie(let movie): focusedMovieAnchor = movie.id
                        case .show(let show): focusedMovieAnchor = show.episodes.first?.id
                        }
                    } else { focusedMovieAnchor = nil }
                }
            }
            .onAppear {
                guard let lastFocusedItem else { return }
                let focusIDs = Set((collection == .continueWatching ? suggestions.map(\.id) : items.map(\.id)) + ["back"])
                let replacement = focusedMovieAnchor.flatMap { anchor -> String? in
                    if collection == .continueWatching { return suggestions.first { $0.movie.id == anchor }?.id }
                    return items.first { item in
                        switch item {
                        case .movie(let movie): return movie.id == anchor
                        case .show(let show): return show.episodes.contains { $0.id == anchor }
                        }
                    }?.id
                }
                let target = focusIDs.contains(lastFocusedItem) ? lastFocusedItem : (replacement.flatMap { focusIDs.contains($0) ? $0 : nil } ?? "back")
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(target, anchor: .center)
                    await Task.yield()
                    focusedItem = target
                }
            }
        }
        .background(CinemaBackground())
        .navigationDestination(for: SearchShowSelection.self) { selection in
            HomeCollectionShowView(collection: collection, selection: selection)
        }
    }

    @ViewBuilder private func collectionCard(_ item: CollectionRowItem) -> some View {
        switch item {
        case .movie(let movie):
            NavigationLink(value: movie) {
                PosterView(movie: movie, isFocused: focusedItem == item.id)
            }.accessibilityLabel(movie.title)
        case .show(let show):
            NavigationLink(value: SearchShowSelection(show)) {
                TVShowArtwork(title: show.title,
                              subtitle: "\(show.seasons.count) \(show.seasons.count == 1 ? "season" : "seasons")",
                              path: show.posterPath, focused: focusedItem == item.id)
            }.accessibilityLabel("\(show.title), \(show.seasons.count) \(show.seasons.count == 1 ? "season" : "seasons")")
        }
    }
}

private struct HomeCollectionShowView: View {
    let collection: HomeCollection
    let selection: SearchShowSelection
    @Query private var library: [Movie]
    @Environment(\.dismiss) private var dismiss
    @State private var currentShowID: String?

    var body: some View {
        let show = selection.resolve(in: collection.movies(in: library), currentShowID: currentShowID)
        Group {
            if let show { TVShowDestination(episodes: show.episodes, initialShowID: show.id) }
            else { Color.clear.task { dismiss() } }
        }
        .onChange(of: show?.id, initial: true) { _, id in currentShowID = id }
    }
}
