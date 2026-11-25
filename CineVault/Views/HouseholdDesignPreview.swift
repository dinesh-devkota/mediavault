#if DEBUG
import SwiftData
import SwiftUI

/// Isolated UI-test library: no Keychain access, no persistent media database and no NAS requests.
/// The fixture never authenticates an existing installation or exposes a path to its credentials.
enum HouseholdPreview {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-preview-household") }
    private final class MemoryRecord { var value: String? }
    static let store: HouseholdStore = {
        let record = MemoryRecord()
        let defaults = UserDefaults(suiteName: "MediaVault.HouseholdPreview.\(UUID())")!
        return HouseholdStore(defaults: defaults, read: { record.value }, write: { record.value = $0 }, erase: { record.value = nil })
    }()
}

@MainActor
struct HouseholdDesignPreview: View {
    @State private var ready = false
    @State private var error: String?
    @StateObject private var scanner = LibraryScanner()
    @State private var container: ModelContainer
    init() {
        _container = State(initialValue: try! ModelContainer(for: MediaSource.self, Movie.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }
    var body: some View {
        Group {
            if ready { RootView().environmentObject(scanner).modelContainer(container) }
            else if let error { Text(error) }
            else { ProgressView("Preparing the sample household…") }
        }
        .task {
            guard !ready else { return }
            do {
                let context = container.mainContext
                let source = MediaSource(name: "Sample media", host: "household-fixture.invalid", share: "Media", rootPath: "", username: "")
                context.insert(source)
                for (path, title, rating) in [
                    ("Family/Family Adventure.mp4", "Family Adventure", "PG"),
                    ("Private/Restricted Feature.mp4", "Restricted Feature", "R"),
                    ("Family/Unrated Feature.mp4", "Unrated Feature", ""),
                    ("Private/Private Memory.jpg", "Private Memory", "")
                ] {
                    let movie = Movie(filePath: path, fileSize: 10_000_000, source: source)
                    movie.setTitle(title); movie.usContentRating = rating.isEmpty ? nil : rating
                    movie.metadataFetched = true; movie.usContentRatingFetched = true
                    context.insert(movie)
                }
                try context.save()
                let store = HouseholdPreview.store
                try await store.setupAsync(pin: "328614", confirmation: "328614", intent: store.authenticationToken)
                guard let admin = store.profiles.first(where: \.isAdmin) else { return }
                try await store.unlockAsync(admin.id, pin: "328614", intent: store.authenticationToken)
                var kids = HouseholdProfile(name: "Kids")
                kids.allowedFolders = [HouseholdFolder(sourceID: source.id, path: "Family")]
                kids.maximumMovieRating = "PG"; kids.maximumTVRating = "TV-PG"
                try await store.saveViewer(kids, newPIN: nil, confirmation: "", adminPIN: "328614", intent: store.authenticationToken)
                let guest = HouseholdProfile(name: "Guest")
                try await store.saveViewer(guest, newPIN: nil, confirmation: "", adminPIN: "328614", intent: store.authenticationToken)
                store.lock(); ready = true
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
