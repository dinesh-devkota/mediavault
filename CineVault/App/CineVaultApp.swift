import Foundation
import CineVaultCore
import SwiftData
import SwiftUI

@main
struct CineVaultApp: App {
    @StateObject private var scanner = LibraryScanner()
    @StateObject private var playbackServices = PlaybackServices()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if PhotoDesignPreview.isEnabled {
                    PhotoDesignPreview()
                } else if ProcessInfo.processInfo.arguments.contains("--ui-preview-nas-folder") {
                    NASSetupView.folderPreview.environmentObject(scanner)
                        .modelContainer(for: [MediaSource.self, Movie.self], inMemory: true)
                } else if ProcessInfo.processInfo.arguments.contains("--ui-preview-nas") {
                    NASSetupView().environmentObject(scanner)
                        .modelContainer(for: [MediaSource.self, Movie.self], inMemory: true)
                } else if DesignPreview.isEnabled {
                    DesignPreview()
                        .environmentObject(scanner)
                } else {
                    RootView()
                        .environmentObject(scanner)
                        .modelContainer(for: [MediaSource.self, Movie.self])
                }
                #else
                RootView()
                    .environmentObject(scanner)
                    .modelContainer(for: [MediaSource.self, Movie.self])
                #endif
            }
            .environmentObject(playbackServices)
        }
    }
}

struct RootView: View {
    private enum Tab: Hashable { case home, library, photos, search, sources, settings }
    @State private var tab: Tab = .home
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var scanner: LibraryScanner
    @EnvironmentObject private var playbackServices: PlaybackServices

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeView(openPhotos: { tab = .photos }, openSources: { tab = .sources }).movieDestination()
            }.tabItem { Text("Home") }.tag(Tab.home)
            NavigationStack { LibraryView().movieDestination() }.tabItem { Text("Library") }.tag(Tab.library)
            NavigationStack { PhotosView().movieDestination() }.tabItem { Text("Photos") }.tag(Tab.photos)
            NavigationStack { SearchView().movieDestination() }.tabItem { Image(systemName: "magnifyingglass") }.tag(Tab.search)
            NavigationStack { SourcesView() }.tabItem { Text("Sources") }.tag(Tab.sources)
            NavigationStack { SettingsView() }.tabItem { Image(systemName: "gearshape") }.tag(Tab.settings)
        }
        .tint(CinemaTheme.accent)
        .preferredColorScheme(.dark)
        .task {
            #if DEBUG
            if DesignPreview.isEnabled { return }
            #endif
            await playbackServices.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await playbackServices.refresh() }
            }
        }
        .task {
            #if DEBUG
            if DesignPreview.isEnabled { return }
            #endif
            await scanner.scanAll(context: context)
        }
    }
}

extension View {
    @MainActor
    func movieDestination() -> some View {
        navigationDestination(for: Movie.self) { movie in
            if MediaFile.isPhoto(path: movie.filePath) { PhotoDestination(photo: movie) }
            else { MovieDetailView(movie: movie) }
        }
    }
}
