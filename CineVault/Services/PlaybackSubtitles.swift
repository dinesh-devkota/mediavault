import AVFoundation
import CineVaultCore
import SwiftUI

/// AVFoundation may publish a selection after select(_:in:) returns. Keep the expected
/// target until observed, without swallowing a different choice made in the native UI.
struct NativeSubtitleSelectionTracker {
    private struct Expected { let index: Int? }
    private var observed: Int?
    private var expected: Expected?

    init(current: Int?) { observed = current }

    mutating func request(_ target: Int?, current: Int?) {
        observed = current
        expected = Expected(index: target)
    }

    /// True only when the actual selection changed independently of our pending request.
    mutating func changed(to current: Int?) -> Bool {
        if let expected, expected.index == current {
            self.expected = nil; observed = current
            return false
        }
        guard current != observed else { return false }
        observed = current; expected = nil
        return true
    }
}

/// Only sibling sidecars are considered. No search, upload, or write is made to the NAS.
enum LocalSubtitleService {
    static func discover(config: SourceConfig, videoPath: String, preferredLanguage: String = "en",
                         list: (SourceConfig, String) async throws -> [NASDirectoryEntry] = {
                             try await SMBService.shared.listEntries($0, directory: $1)
                         }) async throws -> [SubtitleFile] {
        guard let directory = SubtitleFile.directory(for: videoPath, rootPath: config.rootPath, caseSensitive: config.isWebDAV),
              !config.excludesFile(videoPath) else { throw SMBError.sourceChanged }
        let entries = try await list(config, directory)
        try Task.checkCancellation()
        let matches = entries.prefix(4096).filter { !$0.isDirectory }.compactMap {
            SubtitleFile.match(name: $0.name, videoPath: videoPath, rootPath: config.rootPath,
                               ignoredFolders: config.ignoredFolders, ignoredFiles: config.ignoredFiles, caseSensitive: config.isWebDAV)
        }.sorted {
            let left = PlaybackSubtitles.sameLanguage($0.language, preferredLanguage)
            let right = PlaybackSubtitles.sameLanguage($1.language, preferredLanguage)
            if left != right { return left }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return Array(matches.prefix(8))
    }

    static func read(_ file: SubtitleFile, config: SourceConfig,
                     size: (SourceConfig, String) async throws -> Int64 = { try await SMBService.shared.fileSize($0, path: $1) },
                     read: (SourceConfig, String, Int) async throws -> Data = { try await SMBService.shared.read($0, path: $1, offset: 0, length: $2) }) async throws -> SubtitleDocument {
        guard SubtitleFile.safePath(file.path, within: config.rootPath, caseSensitive: config.isWebDAV) != nil, !config.excludesFile(file.path) else { throw SMBError.sourceChanged }
        let length = try await size(config, file.path)
        try Task.checkCancellation()
        guard length > 0, length <= SubtitleDocument.maximumBytes else { throw SubtitleError.tooLarge }
        let data = try await read(config, file.path, Int(length))
        try Task.checkCancellation()
        guard data.count == Int(length) else { throw SMBError.unexpectedEndOfFile }
        return try SubtitleDocument.parse(data)
    }
}

@MainActor
final class PlaybackSubtitles: ObservableObject {
    nonisolated static let preferenceKey = "playback.subtitlePreference"
    struct Embedded: Identifiable {
        let id: Int
        let option: AVMediaSelectionOption
        var label: String { option.displayName }
        var preference: String { "embedded|" + (option.extendedLanguageTag ?? option.locale?.identifier ?? option.displayName) }
    }
    struct ProviderTracks {
        let files: [SubtitleFile]
        let read: (SubtitleFile) async throws -> SubtitleDocument
    }
    var providerTracks: ProviderTracks?
    struct ExternalEmbedded: Identifiable, Equatable {
        let id: String
        let label: String
        let language: String?
        var preference: String { "engine|" + (language ?? label) }
    }
    struct ExternalPlayback {
        let time: () -> Double
        let tracks: () -> [ExternalEmbedded]
        let selected: () -> String?
        let select: (String?) -> Void
    }
    var externalPlayback: ExternalPlayback?
    @Published private(set) var externalEmbedded: [ExternalEmbedded] = []
    private var externalTimer: Task<Void, Never>?
    private var externalPreferenceRestored = false

    @Published private(set) var local: [SubtitleFile] = []
    @Published private(set) var embedded: [Embedded] = []
    @Published private(set) var online: [SubDLSubtitle] = []
    @Published private(set) var searching = false
    @Published private(set) var onlineMessage: String?
    @Published private(set) var selection = "system"
    @Published private(set) var caption = ""
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    @Published var presented = false
    @Published private(set) var delay: Double = 0
    private let player: AVPlayer
    private let movie: Movie
    private let config: SourceConfig
    private let path: String
    private let defaults: UserDefaults
    private var group: AVMediaSelectionGroup?
    private var document: SubtitleDocument?
    private var task: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var observer: Any?
    private var mediaObserver: NSObjectProtocol?
    private var jumpObserver: NSObjectProtocol?
    private var started = false
    private var stopped = false
    private var generation = UUID()
    private var localPreference: String?
    private var nativeLoaded = false
    private var nativeSelection = NativeSubtitleSelectionTracker(current: nil)

    init(player: AVPlayer, movie: Movie, config: SourceConfig, defaults: UserDefaults = .standard) {
        self.player = player; self.movie = movie; self.config = config; path = movie.filePath; self.defaults = defaults
    }

    func start() {
        guard !started, !stopped else { return }
        if let externalPlayback {
            started = true; loading = true; nativeLoaded = true
            externalTimer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, !self.stopped else { return }
                    let tracks = externalPlayback.tracks()
                    if self.externalEmbedded != tracks { self.externalEmbedded = tracks }
                    if !tracks.isEmpty, !self.externalPreferenceRestored, !self.loading {
                        self.externalPreferenceRestored = true
                        self.restorePreference()
                    }
                    self.updateCaption()
                }
            }
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    self.local = try await LocalSubtitleService.discover(config: self.config, videoPath: self.path, preferredLanguage: self.preferredLanguage)
                    try Task.checkCancellation()
                    guard self.sourceUnchanged else { throw SMBError.sourceChanged }
                    self.externalEmbedded = externalPlayback.tracks(); self.loading = false; self.restorePreference()
                } catch is CancellationError { }
                catch { guard !self.stopped else { return }; self.loading = false; self.message = "Local subtitles could not be read. Playback can continue."; self.restorePreference() }
            }
            return
        }
        guard let item = player.currentItem else { return }
        started = true; loading = true
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCaption() }
        }
        jumpObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCaption() }
        }
        mediaObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.nativeSelectionChanged() }
        }
        task = Task { [weak self] in
            guard let self else { return }
            // Media selection must be known before displaying external captions, to avoid two tracks at once.
            do {
                self.group = try await item.asset.loadMediaSelectionGroup(for: .legible)
                try Task.checkCancellation()
                guard self.sourceUnchanged else { throw SMBError.sourceChanged }
                self.embedded = (self.group?.options ?? []).enumerated().map { Embedded(id: $0.offset, option: $0.element) }
                self.nativeLoaded = true
                self.nativeSelection = NativeSubtitleSelectionTracker(current: self.currentNativeSelection)
                if let tracks = self.providerTracks {
                    self.local = tracks.files
                } else {
                    self.local = try await LocalSubtitleService.discover(config: self.config, videoPath: self.path,
                                                                         preferredLanguage: self.preferredLanguage)
                }
                try Task.checkCancellation()
                guard self.sourceUnchanged else { throw SMBError.sourceChanged }
                self.loading = false
                self.restorePreference()
            } catch is CancellationError { }
            catch {
                guard !self.stopped else { return }
                self.loading = false
                self.message = "Local subtitles could not be read. Playback can continue."
                self.restorePreference()
            }
        }
    }

    private var sourceUnchanged: Bool {
        !stopped && LibrarySearch.isAvailable(movie) && movie.filePath == path && (try? movie.source?.config()) == config
    }

    private func restorePreference() {
        let preference = defaults.string(forKey: Self.preferenceKey) ?? "system"
        if preference == "off" { select("off", remember: false) }
        else if let file = local.first(where: { $0.preference == preference }) { select(file.path, remember: false) }
        else if let native = embedded.first(where: { $0.preference == preference }) { select("embedded:\(native.id)", remember: false) }
        else if let native = externalEmbedded.first(where: { $0.preference == preference }) { select("engine:\(native.id)", remember: false) }
        else if preference != "system" || defaults.bool(forKey: SubtitleSettings.enabledKey) {
            if let file = local.first(where: { Self.sameLanguage($0.language, preferredLanguage) && !$0.forced && !$0.hearingImpaired }) ?? local.first(where: { Self.sameLanguage($0.language, preferredLanguage) }) {
                select(file.path, remember: false)
            } else if let native = embedded.first(where: { Self.sameLanguage($0.option.extendedLanguageTag ?? $0.option.locale?.identifier, preferredLanguage) }) {
                select("embedded:\(native.id)", remember: false)
            } else if let native = externalEmbedded.first(where: { Self.sameLanguage($0.language, preferredLanguage) }) {
                select("engine:\(native.id)", remember: false)
            } else if defaults.bool(forKey: SubtitleSettings.enabledKey) {
                select("system", remember: false)
                findOnline(automatically: true)
            } else {
                select("off", remember: false)
                if message == nil { message = "Your preferred subtitles are unavailable for this episode. Choose another track or use Off." }
            }
        }
        else if preference == "system" { select("system", remember: false) }
        else {
            select("off", remember: false)
            if message == nil { message = "Your preferred subtitles are unavailable for this episode. Choose another track or use Off." }
        }
    }

    func select(_ id: String, remember: Bool = true) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview-playback") {
            print("Playback fixture subtitle action: \(id); stopped=\(stopped)")
        }
        #endif
        guard !stopped else { return }
        generation = UUID(); loadTask?.cancel(); loadTask = nil
        if remember { searchTask?.cancel(); searchTask = nil; searching = false; externalPreferenceRestored = true }
        document = nil; caption = ""; localPreference = nil; delay = 0
        loading = false
        if remember { message = nil }
        if id == "system", remember {
            SubtitleSettings.selectAutomatic(defaults: defaults)
            restorePreference()
            return
        }
        if id == "system" {
            selection = id
            // Preserve AVPlayer's initial system choice. An explicit Automatic action above
            // resolves the full preferred-language chain, with a known native target.
            if remember { defaults.set(id, forKey: Self.preferenceKey) }
        } else if id == "off" {
            guard disableNative() else { return }
            selection = id
            if remember { defaults.set(id, forKey: Self.preferenceKey) }
        } else if let native = externalEmbedded.first(where: { "engine:\($0.id)" == id }), let externalPlayback {
            selection = id; externalPlayback.select(native.id)
            if remember { defaults.set(native.preference, forKey: Self.preferenceKey) }
        } else if let native = embedded.first(where: { "embedded:\($0.id)" == id }), let group {
            selection = id
            selectNative(native.option)
            if remember { defaults.set(native.preference, forKey: Self.preferenceKey) }
        } else if let file = local.first(where: { $0.path == id }) {
            guard disableNative() else { return }
            selection = id; loading = true; localPreference = file.preference
            if remember { defaults.set(file.preference, forKey: Self.preferenceKey) }
            let token = generation
            loadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    guard self.sourceUnchanged else { throw SMBError.sourceChanged }
                    let document: SubtitleDocument
                    if let tracks = self.providerTracks {
                        document = try await tracks.read(file)
                    } else {
                        document = try await LocalSubtitleService.read(file, config: self.config)
                    }
                    try Task.checkCancellation()
                    guard self.generation == token, self.sourceUnchanged else { return }
                    self.document = document; self.loading = false; self.updateCaption()
                } catch is CancellationError { }
                catch {
                    guard !self.stopped, self.generation == token else { return }
                    self.loading = false; self.selection = "off"; self.localPreference = nil
                    self.message = "This subtitle file is unreadable, invalid, or larger than 2 MB. Choose another track; playback can continue."
                    if !remember, self.defaults.bool(forKey: SubtitleSettings.enabledKey) {
                        self.findOnline(automatically: true)
                    }
                }
            }
        }
    }

    private func disableNative() -> Bool {
        if let externalPlayback { externalPlayback.select(nil); return true }
        guard nativeLoaded else {
            if message == nil { message = "Subtitles are still being checked. Try again in a moment." }
            return false
        }
        if let group {
            guard group.allowsEmptySelection else {
                message = "This video requires its embedded caption track. Local subtitles cannot be combined with it."
                return false
            }
            selectNative(nil)
        }
        return true
    }

    private var currentNativeSelection: Int? {
        guard let group, let selected = player.currentItem?.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return embedded.first { $0.option === selected }?.id
    }

    private func selectNative(_ option: AVMediaSelectionOption?) {
        guard let group else { return }
        let target = option.flatMap { option in embedded.first { $0.option === option }?.id }
        nativeSelection.request(target, current: currentNativeSelection)
        player.currentItem?.select(option, in: group)
        // Handles both immediate updates and no-op requests. A deferred update remains pending.
        _ = nativeSelection.changed(to: currentNativeSelection)
    }

    private func nativeSelectionChanged() {
        guard !stopped, nativeLoaded else { return }
        let current = currentNativeSelection
        guard nativeSelection.changed(to: current) else { return }
        // Native picker changes replace the custom track; expected select() results are suppressed.
        generation = UUID(); loadTask?.cancel(); searchTask?.cancel(); searching = false
        document = nil; caption = ""; localPreference = nil; loading = false
        if let native = embedded.first(where: { $0.id == current }) {
            selection = "embedded:\(native.id)"
            defaults.set(native.preference, forKey: Self.preferenceKey)
        } else {
            selection = "off"
            defaults.set("off", forKey: Self.preferenceKey)
        }
    }

    func adjustDelay(_ amount: Double) {
        delay = min(10, max(-10, delay + amount)); updateCaption()
    }

    private func updateCaption() {
        guard !stopped else { return }
        // A native choice always wins, even before its change notification is delivered.
        let nativeSelected = externalPlayback.map { $0.selected() != nil } ?? group.map { player.currentItem?.currentMediaSelection.selectedMediaOption(in: $0) != nil } ?? false
        let text = nativeSelected ? "" : document?.text(at: (externalPlayback?.time() ?? player.currentTime().seconds) - delay) ?? ""
        if caption != text { caption = text }
    }

    var hasLocalSelection: Bool { localPreference != nil }
    private var preferredLanguage: String {
        Self.normalizedLanguage(SubtitleSettings.requestedLanguage(defaults: defaults))
    }

    nonisolated static func sameLanguage(_ candidate: String?, _ preferred: String) -> Bool {
        guard let candidate else { return false }
        let normalizedCandidate = normalizedLanguage(candidate), normalizedPreferred = normalizedLanguage(preferred)
        return normalizedCandidate == normalizedPreferred || (!normalizedPreferred.contains("-") && normalizedCandidate.split(separator: "-").first.map(String.init) == normalizedPreferred)
    }

    nonisolated private static func normalizedLanguage(_ code: String) -> String {
        let aliases = ["eng": "en", "spa": "es", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "ita": "it", "por": "pt", "zho": "zh", "chi": "zh", "jpn": "ja", "kor": "ko", "ara": "ar", "hin": "hi", "rus": "ru", "nld": "nl", "dut": "nl", "swe": "sv", "nor": "no", "dan": "da", "fin": "fi", "pol": "pl", "tur": "tr", "ell": "el", "gre": "el", "heb": "he", "ind": "id", "vie": "vi", "tha": "th", "ukr": "uk", "ces": "cs", "cze": "cs", "ron": "ro", "rum": "ro", "hun": "hu", "ben": "bn", "tam": "ta", "tel": "te", "nep": "ne"]
        var parts = code.lowercased().replacingOccurrences(of: "_", with: "-").components(separatedBy: "-")
        if let first = parts.first, let alias = aliases[first] { parts[0] = alias }
        return parts.joined(separator: "-")
    }
    var canSearchOnline: Bool { onlineQuery != nil }

    var onlineQuery: SubDLSearchQuery? {
        if let episode = movie.episodeInfo, let id = movie.seriesTMDBID, id > 0 {
            return SubDLSearchQuery(tmdbID: id, type: .tv, season: episode.season, episode: episode.episode, language: preferredLanguage)
        }
        guard movie.episodeInfo == nil, let id = movie.tmdbID, id > 0 else { return nil }
        return SubDLSearchQuery(tmdbID: id, type: .movie, language: preferredLanguage)
    }

    func findOnline(automatically: Bool = false) {
        guard !stopped, !searching else { return }
        if automatically && defaults.string(forKey: Self.preferenceKey) == "off" { return }
        guard let query = onlineQuery else {
            onlineMessage = "Match this title in the library before searching online. TV episodes need a matched show, season and episode."
            return
        }
        let key: String
        do {
            guard let saved = try Keychain.get(SubtitleSettings.account), !saved.isEmpty else {
                onlineMessage = "Connect SubDL in Settings, then return here."
                return
            }
            key = saved
        } catch { onlineMessage = "The saved SubDL key could not be read. Try again in Settings."; return }
        searching = true; onlineMessage = nil
        let token = generation
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await SubDLClient().search(query, apiKey: key)
                try Task.checkCancellation()
                guard !self.stopped, self.generation == token, self.sourceUnchanged else { return }
                self.online = results; self.searching = false
                // Jellyfin catalog paths use item IDs instead of the release's filename.
                if automatically, !self.config.isJellyfin, !self.config.isPlex, let exact = Self.automaticMatch(results, videoPath: self.path) {
                    self.selectOnline(exact, remember: false)
                } else if !results.isEmpty {
                    self.onlineMessage = "Subtitles are available. Choose the release that matches your video."
                }
            } catch is CancellationError { }
            catch {
                guard !self.stopped, self.generation == token else { return }
                self.searching = false; self.onlineMessage = error.localizedDescription
            }
        }
    }

    /// A language or title match does not establish the same edit; only one exact release may auto-start.
    static func automaticMatch(_ results: [SubDLSubtitle], videoPath: String) -> SubDLSubtitle? {
        func base(_ path: String) -> String {
            let name = (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            return (["mp4", "mov", "m4v", "mkv", "avi", "srt", "vtt"].contains(ext) ? (name as NSString).deletingPathExtension : name).lowercased()
        }
        let matches = results.filter { ([$0.releaseName] + $0.releaseNames).contains { base($0) == base(videoPath) } }
        return matches.count == 1 ? matches.first : nil
    }

    func selectOnline(_ subtitle: SubDLSubtitle, remember: Bool = true) {
        guard !stopped, nativeLoaded else { return }
        let apiKey: String
        do {
            guard let saved = try Keychain.get(SubtitleSettings.account), !saved.isEmpty else {
                onlineMessage = "Connect SubDL in Settings, then return here."
                return
            }
            apiKey = saved
        } catch { onlineMessage = "The saved SubDL key could not be read. Try again in Settings."; return }
        generation = UUID(); let token = generation
        loadTask?.cancel(); searchTask?.cancel(); searching = false
        document = nil; caption = ""; message = nil; delay = 0
        guard disableNative() else { return }
        selection = "online:\(subtitle.id)"; localPreference = "online|\(subtitle.language)"; loading = true
        if remember { defaults.set(localPreference, forKey: Self.preferenceKey) }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await OnlineSubtitleMemoryCache.shared.data(for: subtitle, apiKey: apiKey)
                try Task.checkCancellation()
                guard !self.stopped, self.generation == token, self.sourceUnchanged else { return }
                self.document = try SubtitleDocument.parse(data)
                self.loading = false; self.updateCaption()
            } catch is CancellationError { }
            catch {
                guard !self.stopped, self.generation == token else { return }
                self.loading = false; self.selection = "off"; self.localPreference = nil
                self.onlineMessage = error is SubtitleError ? "This subtitle file could not be read. Choose another release or use a local SRT or WebVTT file." : error.localizedDescription
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; generation = UUID(); task?.cancel(); loadTask?.cancel(); searchTask?.cancel(); caption = ""; document = nil
        externalTimer?.cancel(); externalTimer = nil; externalEmbedded = []
        presented = false; local = []; embedded = []; online = []; message = nil; onlineMessage = nil
        if let observer { player.removeTimeObserver(observer) }; observer = nil
        if let mediaObserver { NotificationCenter.default.removeObserver(mediaObserver) }; mediaObserver = nil
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }; jumpObserver = nil
    }
}

/// A bounded cache in app memory. Keys and NAS paths are never persisted or sent to a provider.
private actor OnlineSubtitleMemoryCache {
    static let shared = OnlineSubtitleMemoryCache()
    private var entries: [String: Data] = [:]
    private var order: [String] = []
    func data(for subtitle: SubDLSubtitle, apiKey: String) async throws -> Data {
        let key = subtitle.downloadURL.absoluteString + "|" + subtitle.id
        if let data = entries[key] { return data }
        let data = try await SubDLClient().download(subtitle, apiKey: apiKey)
        try Task.checkCancellation()
        _ = try SubtitleDocument.parse(data)
        while order.count >= 8, let first = order.first { entries.removeValue(forKey: first); order.removeFirst() }
        if entries[key] == nil { order.append(key) }
        entries[key] = data
        return data
    }
}

struct SubtitleSelectionView: View {
    @ObservedObject var subtitles: PlaybackSubtitles
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button("Done") { dismiss() }.accessibilityIdentifier("subtitles-done")
                Section("Subtitles") {
                    choice("Off", id: "off")
                    choice("Automatic", id: "system")
                    ForEach(subtitles.embedded) { track in choice(track.label + " · Embedded", id: "embedded:\(track.id)") }
                    ForEach(subtitles.externalEmbedded) { track in choice(track.label + " · Embedded", id: "engine:\(track.id)") }
                }
                Section("From this video’s folder") {
                    if subtitles.loading { ProgressView("Loading subtitles…") }
                    ForEach(subtitles.local) { file in choice(file.label, id: file.path) }
                    if subtitles.local.isEmpty && !subtitles.loading { Text("No matching SRT or WebVTT files found.").foregroundStyle(.secondary) }
                }
                Section("Online · SubDL") {
                    Button(subtitles.searching ? "Searching…" : "Find online subtitles") { subtitles.findOnline() }
                        .disabled(subtitles.searching)
                        .accessibilityIdentifier("subtitles-search-online")
                    if subtitles.searching { ProgressView() }
                    ForEach(subtitles.online) { result in
                        Button { subtitles.selectOnline(result) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(SubtitleSettings.languageName(result.language) + (result.hearingImpaired ? " · SDH" : ""))
                                    Text(result.releaseName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if subtitles.selection == "online:\(result.id)" { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    if let message = subtitles.onlineMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                if subtitles.hasLocalSelection {
                    Section("Timing") {
                        Text(String(format: "Subtitle delay: %+.1f seconds", subtitles.delay))
                        HStack {
                            Button("Earlier −0.5s") { subtitles.adjustDelay(-0.5) }
                            Button("Later +0.5s") { subtitles.adjustDelay(0.5) }
                            Button("Reset timing") { subtitles.adjustDelay(-subtitles.delay) }
                        }
                    }
                }
                if let message = subtitles.message { Text(message).foregroundStyle(.secondary) }
                Section {
                    Text(subtitles.providerTracks == nil
                        ? "Place subtitle files beside the video using the same filename, such as Movie.en.srt or Movie.es.vtt. Your Off or language choice carries to the next episode when available."
                        : "Text subtitle tracks supplied by this Jellyfin server are listed above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Subtitles")
        }
    }

    private func choice(_ title: String, id: String) -> some View {
        Button { subtitles.select(id) } label: {
            HStack { Text(title); Spacer(); if subtitles.selection == id { Image(systemName: "checkmark") } }
        }
        .accessibilityIdentifier(id == "off" ? "subtitles-off" : "subtitle-\(id)")
        .accessibilityValue(subtitles.selection == id ? "Selected" : "Not selected")
    }
}

struct LocalCaptionOverlay: View {
    @ObservedObject var subtitles: PlaybackSubtitles
    var bottomInset: CGFloat? = nil
    static var defaultBottomInset: CGFloat {
        #if os(tvOS)
        return 140
        #else
        return 92
        #endif
    }
    var body: some View {
        VStack {
            Spacer()
            if !subtitles.caption.isEmpty {
                Text(subtitles.caption)
                    #if os(tvOS)
                    .font(.system(size: 34, weight: .semibold))
                    #else
                    .font(.system(size: 19, weight: .semibold))
                    #endif
                    .multilineTextAlignment(.center).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 1400)
                    #if os(tvOS)
                    .padding(.horizontal, 100)
                    #else
                    .padding(.horizontal, 16)
                    #endif
                    .padding(.bottom, bottomInset ?? Self.defaultBottomInset)
                    .accessibilityIdentifier("local-subtitle-caption")
            }
        }.allowsHitTesting(false)
    }
}
