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

    func canResume(_ movie: Movie, household: HouseholdStore = .shared) -> Bool {
        guard household.allows(movie) else { return false }
        #if CINEVAULT_COMMERCIAL
        return commercial.canResume(mediaID: household.playbackID(movie.id)) || movie.isInProgress
        #else
        return movie.isInProgress
        #endif
    }

    func resumePosition(_ movie: Movie, household: HouseholdStore = .shared) -> Double {
        guard household.allows(movie) else { return 0 }
        let position = household.progress(movie.id)?.position ?? movie.playbackPosition
        #if CINEVAULT_COMMERCIAL
        return commercial.resumePosition(mediaID: household.playbackID(movie.id), fallback: position)
        #else
        return position
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
