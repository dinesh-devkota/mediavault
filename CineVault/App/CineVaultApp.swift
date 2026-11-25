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
                if HouseholdPreview.isEnabled {
                    HouseholdDesignPreview()
                } else if HouseholdPreview.isEmbyEntry {
                    NavigationStack { SourcesView() }.environmentObject(scanner)
                        .modelContainer(for: [MediaSource.self, Movie.self], inMemory: true)
                } else if ProcessInfo.processInfo.arguments.contains("--ui-preview-playback") {
                    PlaybackDesignPreview()
                } else if PhotoDesignPreview.isEnabled {
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
    @StateObject private var homeNavigation = HomeCollectionNavigation()
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var scanner: LibraryScanner
    @EnvironmentObject private var playbackServices: PlaybackServices
    @ObservedObject private var household = HouseholdStore.shared

    var body: some View {
        Group {
            if household.isLocked { HouseholdPickerView(household: household) }
            else { unlockedTabs.id(household.generation) }
        }
        .onChange(of: scenePhase) { _, phase in
            household.setActive(phase == .active)
            if phase == .active {
                #if DEBUG
                if HouseholdPreview.isEnabled { return }
                #endif
                Task { await playbackServices.refresh() }
            }
        }
        .onAppear { household.setActive(scenePhase == .active) }
        .onChange(of: household.generation) { _, _ in
            tab = .home; homeNavigation.path = NavigationPath()
        }
        .task {
            #if DEBUG
            if DesignPreview.isEnabled || HouseholdPreview.isEnabled { return }
            #endif
            await playbackServices.refresh()
        }
        .task {
            #if DEBUG
            if DesignPreview.isEnabled || HouseholdPreview.isEnabled { return }
            #endif
            await scanner.scanAll(context: context)
        }
    }

    private var unlockedTabs: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $homeNavigation.path) {
                HomeView(openPhotos: { tab = .photos }, openSources: openSources).movieDestination()
            }.environmentObject(homeNavigation).tabItem { Text("Home") }.tag(Tab.home)
            NavigationStack { LibraryView(openSources: openSources).movieDestination() }.tabItem { Text("Library") }.tag(Tab.library)
            NavigationStack { PhotosView().movieDestination() }.tabItem { Text("Photos") }.tag(Tab.photos)
            NavigationStack { SearchView().movieDestination() }.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(Tab.search)
            if household.isAdmin {
                NavigationStack { adminSources }.tabItem { Text("Sources") }.tag(Tab.sources)
                NavigationStack { adminSettings }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(Tab.settings)
            } else {
                NavigationStack { HouseholdViewerSettings() }.tabItem { Text("Profile") }.tag(Tab.settings)
            }
        }
        .tint(CinemaTheme.accent)
        .preferredColorScheme(.dark)
    }

    private func openSources() {
        if household.isAdmin { tab = .sources }
        else { household.lock() }
    }

    @ViewBuilder private var adminSources: some View {
        #if DEBUG
        if HouseholdPreview.isEnabled {
            ContentUnavailableView("Sample media", systemImage: "externaldrive", description: Text("This isolated preview does not connect to real NAS sources."))
        } else { SourcesView() }
        #else
        SourcesView()
        #endif
    }

    @ViewBuilder private var adminSettings: some View {
        #if DEBUG
        if HouseholdPreview.isEnabled {
            Form {
                NavigationLink("Household profiles") { HouseholdSettingsView() }.accessibilityIdentifier("household-settings")
                Text("Sample household. Real credentials, account settings and media databases are unavailable in this preview.").font(.caption)
            }.navigationTitle("Settings")
        } else { SettingsView() }
        #else
        SettingsView()
        #endif
    }
}

extension View {
    @MainActor
    func movieDestination() -> some View {
        navigationDestination(for: Movie.self) { movie in
            if !HouseholdStore.shared.allows(movie) { HouseholdUnavailableView() }
            else if MediaFile.isPhoto(path: movie.filePath) { PhotoDestination(photo: movie) }
            else { MovieDetailView(movie: movie) }
        }
    }
}
