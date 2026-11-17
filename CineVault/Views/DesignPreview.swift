#if DEBUG
import Foundation
import SwiftData
import SwiftUI

/// An in-memory sample library for visual checks; never touches a real library or NAS.
@MainActor
struct DesignPreview: View {
    static let isDetail = ProcessInfo.processInfo.arguments.contains("--ui-preview-detail")
    static let isFilters = ProcessInfo.processInfo.arguments.contains("--ui-preview-filters")
    static let isSearch = ProcessInfo.processInfo.arguments.contains("--ui-preview-search")
    static let isSearchInput = ProcessInfo.processInfo.arguments.contains("--ui-preview-search-input")
    static let isBulk = ProcessInfo.processInfo.arguments.contains("--ui-preview-bulk")
    static let isBulkShow = ProcessInfo.processInfo.arguments.contains("--ui-preview-bulk-show")
    static let isEnabled = isDetail || isFilters || isSearch || isSearchInput || isBulk || isBulkShow || ProcessInfo.processInfo.arguments.contains("--ui-preview")

    private static let filterPreferences: LibraryPreferences = {
        let suite = "com.dineshdevkota.cinevault.preview.filters"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Preview defaults unavailable") }
        defaults.removePersistentDomain(forName: suite)
        let preferences = LibraryPreferences(defaults: defaults)
        preferences.genres = ["Adventure", "Drama"]
        return preferences
    }()

    private let container: ModelContainer
    private let featuredMovie: Movie
    private let bulkEpisodes: [Movie]

    init() {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: MediaSource.self, Movie.self, configurations: configuration)
            let context = container.mainContext
            let source = MediaSource(name: "Preview Library", host: "preview.invalid",
                                     share: "Movies", rootPath: "", username: "")
            context.insert(source)

            let samples: [(title: String, year: Int, genre: String, overview: String)] = [
                ("Midnight Horizon", 2024, "Adventure", "A journey through distant places and the moments that bring us home."),
                ("The Quiet Orbit", 2022, "Science Fiction", "A lone traveller finds an unexpected connection among the stars."),
                ("Beyond the Pines", 2021, "Drama", "Old friends reunite for a weekend far from the noise of the city."),
                ("A Golden Hour", 2020, "Romance", "Two strangers discover the beauty of taking the long way around."),
                ("Ocean Light", 2023, "Documentary", "A voyage across the water, from first light to the last sunset."),
                ("The Last Signal", 2019, "Thriller", "A mysterious message changes the course of an ordinary night."),
            ]
            var featuredMovie: Movie?
            var bulkEpisodes: [Movie] = []
            for (index, sample) in samples.enumerated() {
                let movie = Movie(filePath: "Movies/\(sample.title).mp4",
                                  fileSize: Int64(index + 2) * 1_000_000_000,
                                  source: source)
                movie.setTitle(sample.title)
                movie.parsedTitle = sample.title
                movie.parsedYear = sample.year
                movie.year = sample.year
                movie.genres = [sample.genre]
                movie.overview = sample.overview
                movie.runtimeMinutes = 105 + index * 3
                movie.rating = 7.8
                movie.dateAdded = Date().addingTimeInterval(-Double(index) * 86_400)
                if index < 4 {
                    movie.playbackPosition = Double(1_800 + index * 480)
                    movie.duration = 6_300
                    movie.lastPlayedAt = Date().addingTimeInterval(-Double(index) * 3_600)
                }
                if index == 0 { featuredMovie = movie }
                context.insert(movie)
            }
            if Self.isSearch || Self.isSearchInput {
                for season in 1...8 {
                    for number in 1...24 {
                        let file = String(format: "TV Shows/24/Season %d/24.S%02dE%02d.mp4", season, season, number)
                        let episode = Movie(filePath: file, fileSize: 100, source: source)
                        episode.resetToFileName()
                        episode.setTitle("Day \(season) · Hour \(number)")
                        episode.genres = ["Drama"]
                        context.insert(episode)
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
                for number in [1, 3, 4] {
                    let path = String(format: "TV Shows/24/Season 1/24.S01E%02d.mp4", number)
                    let episode = Movie(filePath: path, fileSize: 100, source: source)
                    episode.resetToFileName()
                    episode.setTitle("Day 1 · Hour \(number)")
                    episode.dateAdded = .distantPast
                    if number == 1 {
                        episode.isWatched = true
                        episode.lastPlayedAt = Date()
                    }
                    context.insert(episode)
                }
            }
            if Self.isBulkShow {
                for season in 1...2 {
                    for number in 1...2 {
                        let path = String(format: "TV Shows/24/Season %d/24.S%02dE%02d.mp4", season, season, number)
                        let episode = Movie(filePath: path, fileSize: 100, source: source)
                        episode.resetToFileName()
                        episode.setTitle("Day \(season) · Hour \(number)")
                        context.insert(episode)
                        bulkEpisodes.append(episode)
                    }
                }
            }
            try context.save()
            guard let featuredMovie else {
                fatalError("The design preview library is empty.")
            }
            self.container = container
            self.featuredMovie = featuredMovie
            self.bulkEpisodes = bulkEpisodes
        } catch {
            fatalError("Unable to create the in-memory design preview: \(error)")
        }
    }

    var body: some View {
        Group {
            if Self.isBulkShow, let show = TVShowGroup.groups(bulkEpisodes).first {
                NavigationStack {
                    TVShowDestination(episodes: bulkEpisodes, initialShowID: show.id).movieDestination()
                }
                .tint(CinemaTheme.accent)
                .preferredColorScheme(.dark)
            } else if Self.isBulk {
                NavigationStack { LibraryView(previewingBulk: true).movieDestination() }
                    .tint(CinemaTheme.accent)
                    .preferredColorScheme(.dark)
            } else if Self.isSearch || Self.isSearchInput {
                NavigationStack {
                    Group {
                        if Self.isSearch { LibrarySearchResultsView(text: "24") }
                        else { SearchView() }
                    }.movieDestination()
                }
                    .tint(CinemaTheme.accent)
                    .preferredColorScheme(.dark)
            } else if Self.isFilters {
                NavigationStack {
                    LibraryView(previewingGenres: Self.filterPreferences)
                }
                .tint(CinemaTheme.accent)
                .preferredColorScheme(.dark)
            } else if Self.isDetail {
                NavigationStack {
                    MovieDetailView(movie: featuredMovie)
                }
                .tint(CinemaTheme.accent)
                .preferredColorScheme(.dark)
            } else {
                RootView()
            }
        }
        .modelContainer(container)
    }
}
#endif
