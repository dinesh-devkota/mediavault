import AVFoundation
import CineVaultCore
import Foundation
import SwiftUI
import VLCKit
#if CINEVAULT_COMMERCIAL
import CineVaultCommercial
#endif

/// VideoLAN demux/decoding is used only when the native Apple route cannot play the file.
/// All network access goes through MediaByteRelay's live source and household checks.
@MainActor
final class AlternativePlayback: ObservableObject {
    struct Track: Identifiable, Equatable {
        let id: String
        let label: String
        let language: String?
    }
    let engine = VLCMediaPlayer()
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var ready = false
    @Published private(set) var ended = false
    @Published private(set) var failure: String?
    @Published private(set) var audioTracks: [Track] = []
    private let relay: MediaByteRelay
    private var timer: Task<Void, Never>?
    private var parser: VLCMediaParser?
    private var stopped = false
    private var requestedPlayback = false
    private var observedPlaying = false
    private var pendingSeek: Double?
    var tick: (() -> Void)?
    var didEnd: (() -> Void)?
    var failed: ((String) -> Void)?

    static func supports(path: String) -> Bool {
        guard MediaFile.shouldIndex(path: path, size: 1), !MediaFile.isPhoto(path: path) else { return false }
        // Disc images/menus are intentionally excluded from the single-file route.
        return ["mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "ts", "m2ts", "flv", "mpg", "mpeg",
                "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma"].contains((path as NSString).pathExtension.lowercased())
    }

    init(relay: MediaByteRelay) { self.relay = relay }

    func prepare(url: URL) async throws {
        guard let media = VLCMedia(url: url) else { throw PlaybackPreparationError.unsupportedFormat }
        // Do not search sibling/network resources from inside the decoding engine.
        media.addOption(":no-sub-autodetect-file")
        media.addOption(":network-caching=750")
        engine.media = media
        engine.timeChangeUpdateInterval = 0.1
        let parser = VLCMediaParser(library: engine.libraryInstance, timeout: 30_000)
        self.parser = parser
        guard parser.queue(media, options: VLCMediaParsingOptions(rawValue: 1)) == 0 else { throw PlaybackPreparationError.unsupportedFormat }
        defer { parser.cancelAllParsing(); self.parser = nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(35))
        while media.parsedStatus == .none || media.parsedStatus == .pending {
            try Task.checkCancellation()
            guard !stopped, ContinuousClock.now < deadline else { throw PlaybackPreparationError.unsupportedFormat }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard !stopped, media.parsedStatus == .done,
              media.tracksInformation.contains(where: { $0.type == .video || $0.type == .audio }) else {
            throw PlaybackPreparationError.unsupportedFormat
        }
        duration = Double(media.length.intValue) / 1000
        guard duration.isFinite, duration > 0 else { throw PlaybackPreparationError.unsupportedFormat }
        ready = true
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, !self.stopped else { return }; self.update()
            }
        }
    }

    func play() {
        guard ready, !stopped, failure == nil, !ended else { return }
        requestedPlayback = true; engine.play()
    }
    func pause() { requestedPlayback = false; engine.pause(); playing = false }
    func seek(to seconds: Double) {
        guard ready, !stopped, seconds.isFinite else { return }
        let target = min(max(0, seconds), duration)
        if !observedPlaying { engine.media?.addOption(":start-time=\(target)") }
        pendingSeek = target
        if engine.isSeekable { applySeek(target) }
    }
    private func applySeek(_ seconds: Double) {
        engine.time = VLCTime(number: NSNumber(value: seconds * 1000))
        position = seconds; pendingSeek = nil
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; requestedPlayback = false; playing = false; ready = false
        timer?.cancel(); timer = nil; parser?.cancelAllParsing(); parser = nil
        engine.stop(); engine.drawable = nil; relay.stop()
        audioTracks = []; tick = nil; didEnd = nil; failed = nil
    }
    var selectedAudio: String? { engine.audioTracks.first(where: { $0.isSelected })?.trackId }
    func selectAudio(_ id: String) { engine.audioTracks.first(where: { $0.trackId == id })?.isSelectedExclusively = true }
    var textTracks: [Track] {
        engine.textTracks.map { Track(id: $0.trackId, label: $0.trackName, language: $0.language) }
    }
    var selectedText: String? { engine.textTracks.first(where: { $0.isSelected })?.trackId }
    func selectText(_ id: String?) {
        if let id { engine.textTracks.first(where: { $0.trackId == id })?.isSelectedExclusively = true }
        else { engine.deselectAllTextTracks() }
    }

    private func update() {
        guard !stopped else { return }
        let current = Double(engine.time.intValue) / 1000
        if current.isFinite, current >= 0, engine.state != .stopped { position = current }
        let nowPlaying = engine.isPlaying && engine.state == .playing
        if nowPlaying { observedPlaying = true }
        if playing != nowPlaying { playing = nowPlaying }
        if let seek = pendingSeek, engine.isSeekable { applySeek(seek) }
        let tracks = engine.audioTracks.map { Track(id: $0.trackId, label: $0.trackName, language: $0.language) }
        if tracks != audioTracks { audioTracks = tracks }
        if engine.state == .error, failure == nil {
            failure = "This file could not be decoded or its source stopped responding. Check the connection and try another version."
            playing = false; failed?(failure!)
        } else if engine.state == .stopped, requestedPlayback, observedPlaying, !ended, failure == nil {
            // VLC4 reports natural completion as stopped; a manual stop/pause never reaches this branch.
            guard position >= max(0, duration - 1.5) else {
                failure = "Playback stopped before the end of the file. Check the source and try again."
                failed?(failure!); return
            }
            ended = true; playing = false; didEnd?()
        }
        tick?()
    }
}

#if CINEVAULT_COMMERCIAL
extension AlternativePlayback: CommercialPlaybackEngine {
    var playbackReady: Bool { ready }
    var playbackDuration: Double { duration }
    var playbackPosition: Double { position }
    var activelyPlaying: Bool { playing }
    var playbackEnded: Bool { ended }
    var playbackFailure: String? { failure }
    func playAuthorized() { play() }
    func pausePlayback() { pause() }
    func seekPlayback(to seconds: Double) { seek(to: seconds) }
}
#endif

struct AlternativePlayerView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var playback: AlternativePlayback
    @ObservedObject private var subtitles: PlaybackSubtitles
    let close: () -> Void
    @State private var started = false
    @State private var seekValue = 0.0
    @State private var scrubbing = false
    @FocusState private var playFocused: Bool
    @FocusState private var videoFocused: Bool
    @State private var controlsVisible = true
    @State private var controlsTask: Task<Void, Never>?

    init(controller: PlaybackController, playback: AlternativePlayback, close: @escaping () -> Void) {
        self.controller = controller; self.playback = playback; self.close = close; self.subtitles = controller.subtitles
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().contentShape(Rectangle())
                .focusable(!controlsVisible).focused($videoFocused)
                .accessibilityLabel("Show playback controls").onTapGesture { revealControls() }
            AlternativeVideoSurface(playback: playback).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 16) {
                HStack {
                    Button(action: close) { Label("Back", systemImage: "chevron.left") }.accessibilityIdentifier("playback-close")
                    Spacer()
                    Button { revealControls(); controller.subtitles.presented = true } label: { Label("Subtitles", systemImage: "captions.bubble") }
                        .accessibilityIdentifier("playback-subtitles")
                    if playback.audioTracks.count > 1 { Button { revealControls(); controller.audioSelectionPresented = true } label: { Label("Audio", systemImage: "waveform") } }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    Text(controller.movie.title).font(.headline).lineLimit(2)
                    if let episode = controller.movie.episodeInfo { Text("\(episode.seriesTitle) · Season \(episode.season) · Episode \(episode.episode)").font(.caption) }
                    HStack {
                        Text(Self.time(playback.position)).monospacedDigit().accessibilityIdentifier("alternative-position")
                        ProgressView(value: min(playback.position, playback.duration), total: max(1, playback.duration))
                        Text(Self.time(playback.duration)).monospacedDigit()
                    }
                    #if os(iOS)
                    Slider(value: $seekValue, in: 0...max(1, playback.duration), onEditingChanged: { editing in
                        scrubbing = editing; revealControls()
                        if !editing { controller.seek(to: seekValue) }
                    }).accessibilityLabel("Playback position").accessibilityIdentifier("alternative-seek")
                    #endif
                    HStack(spacing: 28) {
                        Button { revealControls(); controller.seek(to: max(0, playback.position - 10)) } label: { Label("Back 10s", systemImage: "gobackward.10") }
                            .accessibilityIdentifier("alternative-rewind")
                        Button { togglePlayback() } label: {
                            Label(playback.playing ? "Pause" : "Play", systemImage: playback.playing ? "pause.fill" : "play.fill")
                        }.focused($playFocused).accessibilityIdentifier("alternative-play-pause")
                        Button { revealControls(); controller.seek(to: min(playback.duration, playback.position + 10)) } label: { Label("Forward 10s", systemImage: "goforward.10") }
                            .accessibilityIdentifier("alternative-forward")
                    }.frame(maxWidth: .infinity)
                }.padding().background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
            }
            #if os(tvOS)
            .padding(48)
            #else
            .padding().labelStyle(.iconOnly)
            #endif
            .buttonStyle(.bordered)
            .opacity(controlsVisible ? 1 : 0).allowsHitTesting(controlsVisible).disabled(!controlsVisible)
            #if CINEVAULT_COMMERCIAL
            if let session = controller.externalCommercialSession {
                ExternalPlaybackAccessView(session: session, close: close)
            }
            #endif
        }
        .task {
            guard !started else { return }; started = true; playFocused = true
            #if CINEVAULT_COMMERCIAL
            controller.externalCommercialSession?.start()
            #else
            controller.play()
            #endif
        }
        .onChange(of: playback.position) { _, value in if !scrubbing { seekValue = value } }
        .onChange(of: playback.playing) { _, _ in revealControls() }
        .onChange(of: subtitles.presented) { _, _ in revealControls() }
        .onChange(of: controller.audioSelectionPresented) { _, _ in revealControls() }
        .onDisappear { controlsTask?.cancel() }
        .sheet(isPresented: $controller.audioSelectionPresented) {
            NavigationStack {
                List {
                    Button("Done") { controller.audioSelectionPresented = false }
                    ForEach(playback.audioTracks) { track in
                        Button { playback.selectAudio(track.id); controller.audioSelectionPresented = false } label: {
                            HStack { Text(track.label); Spacer(); if playback.selectedAudio == track.id { Image(systemName: "checkmark") } }
                        }
                    }
                }.navigationTitle("Audio")
            }
        }
        #if os(tvOS)
        .onPlayPauseCommand { togglePlayback() }
        .onMoveCommand { _ in revealControls() }
        #endif
    }
    private func togglePlayback() {
        if playback.playing { controller.pause() } else { controller.play() }
        revealControls()
    }
    private func revealControls() {
        controlsTask?.cancel()
        let wasHidden = !controlsVisible
        controlsVisible = true; videoFocused = false
        if wasHidden { playFocused = true }
        guard playback.playing, !controller.isPresentingPlaybackOptions, !scrubbing else { return }
        controlsTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard playback.playing, !controller.isPresentingPlaybackOptions, !scrubbing else { return }
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }; playFocused = false; videoFocused = true
        }
    }
    private static func time(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? Int(seconds) : 0)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}

#if CINEVAULT_COMMERCIAL
private struct ExternalPlaybackAccessView: View {
    @ObservedObject var session: CommercialExternalPlaybackSession
    let close: () -> Void
    var body: some View {
        if session.errorMessage != nil || session.requiresPurchase || !session.prepared {
            ZStack {
                Color.black.opacity(0.94).ignoresSafeArea()
                VStack(spacing: 24) {
                    if let message = session.errorMessage { Text("Playback unavailable").font(.title); Text(message) }
                    else if session.requiresPurchase {
                        Text("License required").font(.title)
                        Text("Purchase or restore a license in Settings, then continue this video.")
                        Button("Continue after purchase") { session.continueAfterPurchase() }.disabled(!session.services.isUnlocked)
                    } else { ProgressView("Checking playback access…") }
                    Button("Back", action: close).accessibilityIdentifier("playback-access-back")
                }.padding(48)
            }.allowsHitTesting(true)
        }
    }
}
#endif

struct AlternativeVideoSurface: UIViewRepresentable {
    let playback: AlternativePlayback
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .black; playback.engine.drawable = view; return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { if playback.engine.drawable == nil { playback.engine.drawable = uiView } }
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) { }
}
