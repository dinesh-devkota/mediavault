import Combine
import Foundation
#if CINEVAULT_COMMERCIAL
import CineVaultCommercial
#endif

@MainActor
final class ContinuousPlayback: ObservableObject {
    nonisolated static let enabledKey = "playback.continuousTV"
    @Published private(set) var controller: PlaybackController
    @Published private(set) var next: WatchSuggestion?
    @Published private(set) var secondsRemaining = 10
    @Published private(set) var preparing = false
    @Published private(set) var message: String?
    private let services: PlaybackServices
    private let defaults: UserDefaults
    private let library: () -> [Movie]
    private let prepare: (Movie, Bool, PlaybackServices) async throws -> PlaybackController?
    private var observation: AnyCancellable?
    private var errorObservation: AnyCancellable?
    private var commercialObservation: AnyCancellable?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    private var active = true
    private var handled: Set<UUID> = []
    private var visited: Set<UUID> = []

    init(controller: PlaybackController, services: PlaybackServices, defaults: UserDefaults = .standard,
         library: @escaping () -> [Movie],
         prepare: @escaping (Movie, Bool, PlaybackServices) async throws -> PlaybackController? = {
             try await PlaybackController.prepare(movie: $0, resume: $1, services: $2)
         }) {
        self.controller = controller; self.services = services; self.defaults = defaults
        self.library = library; self.prepare = prepare; visited.insert(controller.movie.id)
        observe()
    }

    private func observe() {
        observation = controller.$didEndNaturally.removeDuplicates().sink { [weak self] ended in
            guard ended else { return }
            // @Published emits before storage changes. Start only after the actual end state is visible.
            Task { @MainActor [weak self] in self?.offerNext() }
        }
        errorObservation = controller.$playbackError.sink { [weak self] error in
            if error != nil { self?.cancel() }
        }
        #if CINEVAULT_COMMERCIAL
        commercialObservation = controller.commercialSession.$endedSuccessfully.removeDuplicates().sink { [weak self] ended in
            guard ended else { return }
            Task { @MainActor [weak self] in self?.offerNext() }
        }
        #endif
    }

    /// Public to tests so countdown eligibility can be exercised without a ten-second wall-clock wait.
    func offerNext(startTimer: Bool = true) {
        guard !stopped, active, !controller.subtitles.presented, controller.permitsContinuation, defaults.bool(forKey: Self.enabledKey),
              !handled.contains(controller.movie.id),
              let suggestion = ContinueWatching.next(after: controller.movie, in: library()),
              !visited.contains(suggestion.movie.id) else { return }
        handled.insert(controller.movie.id)
        next = suggestion; secondsRemaining = 10; message = nil
        guard startTimer else { return }
        let token = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.generation == token else { return }
                self.tick()
                if self.next == nil || self.preparing { return }
            }
        }
    }

    func tick() {
        guard next != nil, !preparing else { return }
        guard !stopped, active, !controller.subtitles.presented, defaults.bool(forKey: Self.enabledKey), controller.permitsContinuation else { cancel(); return }
        secondsRemaining = max(0, secondsRemaining - 1)
        if secondsRemaining == 0 { playNow() }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        next = nil; preparing = false
    }

    func playNow() {
        guard !stopped, active, !controller.subtitles.presented, !preparing, let expected = next else { return }
        guard defaults.bool(forKey: Self.enabledKey), controller.permitsContinuation,
              let fresh = ContinueWatching.next(after: controller.movie, in: library()),
              fresh.movie.id == expected.movie.id, !visited.contains(fresh.movie.id) else { cancel(); return }
        task?.cancel(); generation = UUID(); let token = generation
        preparing = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // prepare() checks live availability/source identity. A new commercial session performs
                // its own verified entitlement check before playing or consuming a trial play.
                guard let candidate = try await self.prepare(fresh.movie, fresh.movie.isInProgress, self.services) else { throw PlaybackPreparationError.fileUnavailable }
                guard !Task.isCancelled, !self.stopped, self.active, !self.controller.subtitles.presented, self.generation == token,
                      self.defaults.bool(forKey: Self.enabledKey),
                      self.controller.permitsContinuation,
                      ContinueWatching.next(after: self.controller.movie, in: self.library())?.movie.id == fresh.movie.id else {
                    candidate.stop(saveProgress: false)
                    if self.generation == token { self.cancel() }
                    return
                }
                self.controller.stop()
                self.controller = candidate
                self.visited.insert(candidate.movie.id)
                self.next = nil; self.preparing = false; self.task = nil
                self.observe()
            } catch is CancellationError { }
            catch {
                guard !self.stopped, self.generation == token else { return }
                self.cancel()
                self.message = "The next episode could not be opened. Check its source and try it from the library."
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; cancel(); observation = nil; errorObservation = nil; commercialObservation = nil; controller.stop()
    }

    func setActive(_ value: Bool) {
        active = value
        if !value { cancel() }
    }
}
