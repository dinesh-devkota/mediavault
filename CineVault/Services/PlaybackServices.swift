import Combine
import SwiftUI
#if CINEVAULT_COMMERCIAL
import CineVaultCommercial
#endif

/// Public builds are self-contained; official builds supply a private access module.
@MainActor
final class PlaybackServices: ObservableObject {
    #if CINEVAULT_COMMERCIAL
    let commercial = CommercialServices()
    private var observation: AnyCancellable?

    init() {
        observation = commercial.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    #endif

    func refresh() async {
        #if CINEVAULT_COMMERCIAL
        await commercial.refresh()
        #endif
    }

    func canResume(_ movie: Movie) -> Bool {
        #if CINEVAULT_COMMERCIAL
        return commercial.canResume(mediaID: HouseholdStore.shared.playbackID(movie.id)) || movie.isInProgress
        #else
        return movie.isInProgress
        #endif
    }

    func resumePosition(_ movie: Movie) -> Double {
        #if CINEVAULT_COMMERCIAL
        return commercial.resumePosition(mediaID: HouseholdStore.shared.playbackID(movie.id), fallback: movie.householdPosition)
        #else
        return movie.householdPosition
        #endif
    }

    @discardableResult
    func resetProgress(_ movie: Movie) -> Bool {
        guard HouseholdStore.shared.allows(movie) else { return false }
        #if CINEVAULT_COMMERCIAL
        guard commercial.discardResume(mediaID: HouseholdStore.shared.playbackID(movie.id)) else { return false }
        #endif
        movie.householdPosition = 0
        return true
    }
}
