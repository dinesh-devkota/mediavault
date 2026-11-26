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
                } else if ProcessInfo.processInfo.arguments.contains("--ui-test-empty-library") {
                    RootView()
                        .environmentObject(scanner)
                        .modelContainer(for: [MediaSource.self, Movie.self], inMemory: true)
                } else if ProcessInfo.processInfo.arguments.contains("--ui-preview-alternative-playback") {
                    AlternativePlaybackDesignPreview()
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
                } else if LibraryFeaturesPreview.isEnabled {
                    LibraryFeaturesDesignPreview()
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
    #if os(iOS)
    private enum ManagementDestination: Hashable { case sources, settings }
    @State private var managementPath: [ManagementDestination] = []
    #endif
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
            tab = .home
            homeNavigation.path = NavigationPath()
            #if os(iOS)
            managementPath.removeAll()
            #endif
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
            }.environmentObject(homeNavigation).tabItem { tabLabel("Home", icon: "house") }.tag(Tab.home)
            NavigationStack { LibraryView(openSources: openSources).movieDestination() }.tabItem { tabLabel("Library", icon: "film") }.tag(Tab.library)
            NavigationStack { PhotosView().movieDestination() }.tabItem { tabLabel("Photos", icon: "photo.on.rectangle") }.tag(Tab.photos)
            NavigationStack { SearchView().movieDestination() }.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(Tab.search)
            if household.isAdmin {
                #if os(iOS)
                mobileManagement.tabItem { Label("Manage", systemImage: "gearshape") }.tag(Tab.settings)
                #else
                NavigationStack { adminSources }.tabItem { Text("Sources") }.tag(Tab.sources)
                NavigationStack { adminSettings }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(Tab.settings)
                #endif
            } else {
                NavigationStack { HouseholdViewerSettings() }.tabItem { tabLabel("Profile", icon: "person.crop.circle") }.tag(Tab.settings)
            }
        }
        .tint(CinemaTheme.accent)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func tabLabel(_ title: LocalizedStringKey, icon: String) -> some View {
        #if os(iOS)
        Label(title, systemImage: icon)
        #else
        Text(title)
        #endif
    }

    #if os(iOS)
    private var mobileManagement: some View {
        NavigationStack(path: $managementPath) {
            List {
                NavigationLink(value: ManagementDestination.sources) {
                    Label("Media sources", systemImage: "externaldrive")
                }
                .accessibilityIdentifier("manage-media-sources")
                NavigationLink(value: ManagementDestination.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("manage-settings")
            }
            .navigationTitle("Manage")
            .navigationDestination(for: ManagementDestination.self) { destination in
                if !household.isAdmin { HouseholdUnavailableView() }
                else {
                    switch destination {
                    case .sources: adminSources
                    case .settings: adminSettings
                    }
                }
            }
        }
    }
    #endif

    private func openSources() {
        guard household.isAdmin else { household.lock(); return }
        #if os(iOS)
        tab = .settings
        managementPath = [.sources]
        #else
        tab = .sources
        #endif
    }

    @ViewBuilder private var adminSources: some View {
        #if DEBUG
        if HouseholdPreview.isEnabled && !ProcessInfo.processInfo.arguments.contains("--ui-preview-plex-entry") {
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
