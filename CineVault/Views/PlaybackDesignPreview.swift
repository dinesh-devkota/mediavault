#if DEBUG
import AVFoundation
import SwiftData
import SwiftUI

/// Explicit UI-test launch only; an isolated model and preferences use the synthetic local SMB share.
@MainActor
struct PlaybackDesignPreview: View {
    private static let suite = "com.dineshdevkota.cinevault.preview.playback"
    @State private var controller: PlaybackController?
    @State private var error: String?
    @StateObject private var fixture = Fixture()
    @EnvironmentObject private var services: PlaybackServices

    @MainActor
    private final class Fixture: ObservableObject {
        let defaults: UserDefaults
        let source: MediaSource
        let episodes: [Movie]
        private let credentialKey = "source-ED584ED6-C701-4F6C-A9FA-EA7D73EE1B8B"
        init() {
            defaults = UserDefaults(suiteName: PlaybackDesignPreview.suite)!
            defaults.removePersistentDomain(forName: PlaybackDesignPreview.suite)
            defaults.set(true, forKey: ContinuousPlayback.enabledKey)
            defaults.set("off", forKey: PlaybackSubtitles.preferenceKey)
            source = MediaSource(name: "Playback fixture", host: "127.0.0.1", port: 1445, share: "MEDIAPLAYBACK", rootPath: "TV Shows", username: "cinevault")
            source.id = UUID(uuidString: "ED584ED6-C701-4F6C-A9FA-EA7D73EE1B8B")!
            let source = source
            episodes = [1, 2, 4].map { number in
                let movie = Movie(filePath: "TV Shows/Fixture Show/Season 01/Fixture Show.S01E0\(number).mp4", fileSize: 60 * 1024 * 1024, source: source)
                movie.setTitle("Fixture episode \(number)")
                return movie
            }
        }
        deinit { try? Keychain.delete(credentialKey) }
    }

    var body: some View {
        Group {
            if let controller {
                PlaybackScreen(controller: controller, services: services, defaults: fixture.defaults, library: { fixture.episodes })
                    .onAppear {
                        controller.player.pause()
                        controller.player.seek(to: CMTime(seconds: 1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
            } else if let error { Text(error).padding(80) }
            else { ProgressView("Opening playback fixture…") }
        }
        .task {
            guard controller == nil else { return }
            do {
                try fixture.source.setPassword("fixture-only")
                controller = try await PlaybackController.prepare(movie: fixture.episodes[0], resume: false, services: services, defaults: fixture.defaults)
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
