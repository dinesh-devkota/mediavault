#if DEBUG
import SwiftUI

/// Explicit UI tests only: no owner library, household preferences or NAS address is used.
/// The normal preparation path, decoder and transport remain responsible for readiness.
@MainActor
struct AlternativePlaybackDesignPreview: View {
    @StateObject private var fixture = Fixture()
    @EnvironmentObject private var services: PlaybackServices
    @State private var controller: PlaybackController?
    @State private var presented = false
    @State private var attempted = false
    @State private var error: String?

    @MainActor
    private final class Fixture: ObservableObject {
        let defaults: UserDefaults
        let household: HouseholdStore
        let source: MediaSource
        let movie: Movie
        private let credentialKey = "source-58D859F3-E320-490F-B0E0-70E770A4115D"
        init() {
            let suite = "com.dineshdevkota.cinevault.preview.alternative-playback"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(false, forKey: ContinuousPlayback.enabledKey)
            defaults.set("off", forKey: PlaybackSubtitles.preferenceKey)
            defaults.set(false, forKey: SubtitleSettings.enabledKey)
            household = HouseholdStore(defaults: defaults, read: { nil }, write: { _ in }, erase: {})
            source = MediaSource(name: "Broader playback fixture", host: "127.0.0.1", port: 1445,
                                 share: "FORMATPLAYBACK", rootPath: "", username: "cinevault")
            source.id = UUID(uuidString: "58D859F3-E320-490F-B0E0-70E770A4115D")!
            movie = Movie(filePath: "Controls.mkv", fileSize: 1, source: source)
            movie.setTitle("MKV playback controls")
        }
        deinit { try? Keychain.delete(credentialKey) }
    }

    var body: some View {
        Group {
            if let error { Text(error).accessibilityIdentifier("fixture-alternative-error") }
            else if attempted, controller != nil, !presented {
                Text("Playback closed").accessibilityIdentifier("fixture-alternative-closed")
            } else { ProgressView("Opening MKV fixture…") }
        }
        .task {
            guard !attempted else { return }; attempted = true
            do {
                try fixture.source.setPassword("fixture-only")
                controller = try await PlaybackController.prepare(movie: fixture.movie, resume: false, services: services,
                    defaults: fixture.defaults, household: fixture.household)
                guard controller?.alternative != nil else { throw PlaybackPreparationError.unsupportedFormat }
                presented = true
            } catch { self.error = error.localizedDescription }
        }
        .fullScreenCover(isPresented: $presented) {
            if let controller, let playback = controller.alternative {
                PlaybackScreen(controller: controller, services: services, defaults: fixture.defaults, library: { [fixture.movie] })
                    .playbackScreenEdges()
                    .overlay(alignment: .top) { PlaybackProbe(playback: playback).allowsHitTesting(false) }
            }
        }
    }

    private struct PlaybackProbe: View {
        @ObservedObject var playback: AlternativePlayback
        var body: some View {
            VStack(spacing: 2) {
                Text(playback.ready && playback.position > 0.25 ? "Playback advanced" : "Waiting for decoder")
                    .accessibilityIdentifier("fixture-alternative-ready")
                Text(playback.playing ? "Playing" : "Paused").accessibilityIdentifier("fixture-alternative-state")
                Text(String(format: "%.2f", playback.position)).accessibilityIdentifier("fixture-alternative-seconds")
                let request = playback.fixtureSeekRequest
                Text("Seek \(request?.sequence ?? 0)")
                    .accessibilityLabel("\(request?.sequence ?? 0)|\(request?.target ?? -1)|\(request?.submitted ?? false)|\(playback.fixtureDecoderPosition)")
                    .accessibilityIdentifier("fixture-alternative-seek-evidence")
            }.font(.caption2).foregroundStyle(.white).padding(6).background(.black.opacity(0.5))
        }
    }
}
#endif
