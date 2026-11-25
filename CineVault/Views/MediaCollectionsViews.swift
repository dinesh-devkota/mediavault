import CineVaultCore
import SwiftData
import SwiftUI

@MainActor struct CollectionPickerSheet: View {
    let movieIDs: [UUID]
    @Query private var library: [Movie]
    @ObservedObject private var store = LibraryCollectionsStore.shared
    @ObservedObject private var household = HouseholdStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var session = HouseholdStore.shared.sessionToken
    private var movies: [Movie] { library.filter { movieIDs.contains($0.id) && LibraryCollectionsStore.available($0) } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Add \(movies.count) \(movies.count == 1 ? "file" : "files") to a personal collection.")
                    Text("Collections belong to the current profile. Your media files stay where they are.").font(.caption).foregroundStyle(.secondary)
                }
                Section("New collection") {
                    TextField("Collection name", text: $name).accessibilityIdentifier("collection-name")
                    Button("Create & add") {
                        perform { _ = try store.create(name: name, movies: movies, session: session) }
                    }.disabled(movies.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("collection-create-add")
                }
                if !store.collections.isEmpty {
                    Section("Choose a collection") {
                        ForEach(store.collections) { collection in
                            Button(collection.name) { perform { try store.add(movies, to: collection.id, session: session) } }
                                .disabled(movies.isEmpty)
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                Button("Cancel") { dismiss() }
            }.navigationTitle("Add to collection")
        }
        .onChange(of: household.sessionToken) { _, _ in dismiss() }
        .onTVExit { dismiss() }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); dismiss() } catch { self.error = error.localizedDescription }
    }
}

@MainActor struct MediaCollectionsView: View {
    @Query private var library: [Movie]
    @Environment(\.modelContext) private var context
    @ObservedObject private var store = LibraryCollectionsStore.shared
    @ObservedObject private var household = HouseholdStore.shared
    @State private var name = ""
    @State private var error: String?
    @State private var session = HouseholdStore.shared.sessionToken
    @State private var fetching = false
    private var collections: [VisibleMediaCollection] { MediaCollections.visible(library: library, custom: store.collections) }

    var body: some View {
        List {
            Section("Your collections") {
                TextField("New collection name", text: $name).accessibilityIdentifier("collection-new-name")
                Button("Create collection") {
                    do { _ = try store.create(name: name, movies: [], session: session); name = ""; error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("collection-create")
                if let error { Text(error).foregroundStyle(.orange) }
            }
            if household.isAdmin {
                Section("Movie series") {
                    Button(fetching ? "Finding movie series…" : "Find movie series") {
                        fetching = true; error = nil
                        Task { @MainActor in
                            defer { fetching = false }
                            guard household.sessionIsCurrent(session), household.isAdmin else { return }
                            do {
                                if let result = try await MetadataService.shared.refreshCollections(in: context) {
                                    error = result.failureMessage ?? "Movie series updated. NFO collections are included automatically when you scan."
                                } else { error = "NFO collections work without an account. To find online movie series, add your free TMDB key in Settings first." }
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(fetching)
                    Text("Matches existing TMDB titles to movie series. Local NFO collections are included automatically.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                if collections.isEmpty {
                    Text("Create a collection, then open a title and choose Add to collection. Movie series also appear here when NFO or TMDB details identify a collection.")
                        .foregroundStyle(.secondary)
                }
                ForEach(collections) { collection in
                    NavigationLink {
                        MediaCollectionDetailView(collectionID: collection.id)
                    } label: {
                        HStack(spacing: 20) {
                            Image(systemName: collection.customID == nil ? "film.stack" : "rectangle.stack")
                            VStack(alignment: .leading) {
                                Text(collection.name)
                                Text("\(collection.titleCount) \(collection.titleCount == 1 ? "title" : "titles") · \(collection.customID == nil ? "Movie series" : "Personal")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.accessibilityIdentifier("media-collection-\(collection.id)").accessibilityLabel("\(collection.name), \(collection.titleCount) titles")
                }
            }
        }.navigationTitle("Collections")
    }
}

@MainActor struct MediaCollectionDetailView: View {
    let collectionID: String
    @Query private var library: [Movie]
    @ObservedObject private var store = LibraryCollectionsStore.shared
    @ObservedObject private var household = HouseholdStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var managing = false
    @State private var confirmingDelete = false
    @State private var name = ""
    @State private var error: String?
    @State private var session = HouseholdStore.shared.sessionToken
    private var collection: VisibleMediaCollection? { MediaCollections.visible(library: library, custom: store.collections).first { $0.id == collectionID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let collection {
                    Text(collection.name).font(.largeTitle.bold())
                    Text("\(collection.titleCount) \(collection.titleCount == 1 ? "title" : "titles")").foregroundStyle(.secondary)
                    BulkWatchControl(title: "Select titles", scope: collection.name, movies: collection.movies, startsSelected: false, groupShows: true)
                    if collection.customID != nil {
                        CinemaTheme.actionLayout {
                            Button("Manage titles") { managing = true }.accessibilityIdentifier("collection-manage")
                            Button("Rename") { name = collection.name; renaming = true }
                            Button("Delete collection", role: .destructive) { confirmingDelete = true }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                    if collection.movies.isEmpty {
                        Text("No available titles in this collection. Add titles from their details or the library’s Select action.")
                    } else { CollectionLibraryGrid(movies: LibrarySort.year.sorted(collection.movies)) }
                } else { Text("This collection is no longer available.") }
                Button("Back") { dismiss() }
            }.padding(CinemaTheme.edgeInset)
        }
        .navigationTitle("Collection")
        .sheet(isPresented: $managing) {
            if let id = collection?.customID { CollectionMembershipView(collectionID: id) }
        }
        .sheet(isPresented: $renaming) {
            NavigationStack {
                Form {
                    TextField("Collection name", text: $name).accessibilityIdentifier("collection-rename-name")
                    Button("Save name") {
                        guard let id = collection?.customID else { return }
                        do { try store.rename(id, name: name, session: session); renaming = false; error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                    Button("Cancel") { renaming = false }
                }.navigationTitle("Rename collection")
            }
        }
        .confirmationDialog("Delete this collection? Your media files and viewing history will be kept.", isPresented: $confirmingDelete) {
            Button("Delete collection", role: .destructive) {
                guard let id = collection?.customID else { return }
                do { try store.delete(id, session: session); dismiss() } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

@MainActor private struct CollectionLibraryGrid: View {
    let movies: [Movie]
    @FocusState private var focusedItem: String?
    private let columns = [GridItem(.adaptive(minimum: CinemaTheme.posterWidth, maximum: CinemaTheme.posterWidth), spacing: CinemaTheme.gridSpacing)]
    var body: some View {
        LazyVGrid(columns: columns, spacing: 40) {
            ForEach(CollectionRowItem.grouped(movies, groupVersions: true)) { item in
                Group {
                    switch item {
                    case .movie(let movie):
                        VersionAwareMovieLink(movie: movie, candidates: movies, isFocused: focusedItem == item.id)
                    case .show(let show):
                        NavigationLink { TVShowDestination(episodes: show.episodes, initialShowID: show.id) } label: {
                            TVShowArtwork(title: show.title, subtitle: "\(show.seasons.count) seasons", path: show.posterPath,
                                localMovie: show.episodes.first, localPath: show.episodes.first?.localPosterPath, focused: focusedItem == item.id)
                        }
                    }
                }.buttonStyle(ArtworkButtonStyle()).focusEffectDisabled().focused($focusedItem, equals: item.id)
            }
        }.padding(.vertical, 24)
    }
}

@MainActor private struct CollectionMembershipView: View {
    let collectionID: UUID
    @ObservedObject private var household = HouseholdStore.shared
    @Query private var library: [Movie]
    @ObservedObject private var store = LibraryCollectionsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var session = HouseholdStore.shared.sessionToken
    @State private var error: String?
    private var collection: NamedMediaCollection? { store.collections.first { $0.id == collectionID } }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select a title to add or remove it. This never deletes a media file.").font(.caption)
                    if let error { Text(error).foregroundStyle(.orange) }
                }
                ForEach(LibrarySort.title.sorted(library.filter { LibraryCollectionsStore.available($0) && !MediaFile.isPhoto(path: $0.filePath) })) { movie in
                    let included = collection?.movieIDs.contains(movie.id) == true
                    Button {
                        do {
                            if included { try store.remove(movieIDs: [movie.id], from: collectionID, session: session) }
                            else { try store.add([movie], to: collectionID, session: session) }
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    } label: {
                        HStack {
                            Image(systemName: included ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) { Text(movie.title); Text(movie.fileName).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.accessibilityIdentifier("collection-member-\(movie.fileName)")
                }
                Button("Done") { dismiss() }
            }.navigationTitle(collection?.name ?? "Collection")
        }
    }
}

@MainActor struct MovieVersionsView: View {
    let groupKey: String
    @Query private var library: [Movie]
    @ObservedObject private var household = HouseholdStore.shared
    @Environment(\.dismiss) private var dismiss
    private var movies: [Movie] {
        library.filter { LibraryCollectionsStore.available($0) && MovieVersions.key($0) == groupKey }.sorted { $0.filePath < $1.filePath }
    }
    var body: some View {
        List {
            Section {
                Text(movies.first?.title ?? "Versions").font(.title.bold())
                Text("Choose a version. Each file keeps its own playback position and watched status.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(movies) { movie in
                NavigationLink(value: movie) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(MovieVersions.label(movie)).font(.headline)
                        Text(movie.fileName).font(.caption)
                        Text("\(movie.source?.name ?? "Source") · \(movie.householdWatched ? "Watched" : movie.isInProgress ? "In progress" : "Unwatched")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("movie-version-\(movie.fileName)")
            }
            if movies.isEmpty { Text("No versions are available to this profile.") }
            Button("Back") { dismiss() }
        }.navigationTitle("Choose version")
    }
}

@MainActor struct VersionAwareMovieLink: View {
    let movie: Movie
    let candidates: [Movie]
    var isFocused = false
    private var count: Int {
        candidates.filter { MovieVersions.key($0) == MovieVersions.key(movie) && LibraryCollectionsStore.available($0) }.count
    }
    var body: some View {
        Group {
            if count > 1 {
                NavigationLink { MovieVersionsView(groupKey: MovieVersions.key(movie)) } label: {
                    PosterView(movie: movie, isFocused: isFocused)
                        .overlay(alignment: .topLeading) {
                            Text("\(count) versions").font(.caption.bold()).padding(8)
                                .background(.black.opacity(0.8), in: Capsule()).padding(8)
                        }
                }.accessibilityLabel("\(movie.title), \(count) versions")
            } else {
                NavigationLink(value: movie) { PosterView(movie: movie, isFocused: isFocused) }
                    .accessibilityLabel(movie.title)
            }
        }
    }
}
