#if DEBUG
import SwiftData
import SwiftUI

/// Disposable media and preferences for exercising the actual collection/version UI.
/// It does not connect to a source, read a saved account, or mutate the user's library.
enum LibraryFeaturesPreview {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-preview-library-features") }
    static let defaults = UserDefaults(suiteName: "MediaVault.LibraryFeaturesPreview.\(UUID())")!
    static let household = HouseholdStore(defaults: defaults, read: { nil }, write: { _ in }, erase: {})
}

@MainActor struct LibraryFeaturesDesignPreview: View {
    private let container: ModelContainer
    private let groupKey: String
    init() {
        do {
            container = try ModelContainer(for: MediaSource.self, Movie.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let source = MediaSource(name: "Sample NAS", host: "preview.invalid", share: "Media", rootPath: "", username: "")
            container.mainContext.insert(source)
            var first: Movie?
            for (index, file) in ["Library Feature (2020).mp4", "Library Feature (2020) - Directors Cut.mp4", "Library Sequel (2022).mp4"].enumerated() {
                let movie = Movie(filePath: "Movies/" + file, fileSize: 2_000_000_000 + Int64(index) * 500_000_000, source: source)
                movie.setTitle(index == 2 ? "Library Sequel" : "Library Feature")
                movie.year = index == 2 ? 2022 : 2020; movie.tmdbID = index == 2 ? 910002 : 910001
                movie.localEdition = index == 1 ? "Director’s cut" : "Theatrical"
                movie.collectionName = "Library Saga"; movie.genres = ["Adventure"]
                movie.overview = "A sample title for exploring your library. Choose the edition you want, keep a personal collection, and resume each file independently."
                movie.metadataFetched = true; movie.usContentRating = "PG"; movie.usContentRatingFetched = true
                if index == 1 { movie.playbackPosition = 90; movie.duration = 600 }
                container.mainContext.insert(movie)
                if first == nil { first = movie }
            }
            try container.mainContext.save()
            groupKey = MovieVersions.key(first!)
        } catch { fatalError("Unable to build the isolated library preview: \(error)") }
    }
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Collections") { MediaCollectionsView() }.accessibilityIdentifier("preview-collections")
                NavigationLink("Library Feature · 2 versions") { MovieVersionsView(groupKey: groupKey) }.accessibilityIdentifier("preview-versions")
                NavigationLink("Browse sample library") { LibraryView() }
            }.navigationTitle("MediaVault").movieDestination()
        }
        .modelContainer(container)
        .tint(CinemaTheme.accent)
        .preferredColorScheme(.dark)
    }
}
#endif
