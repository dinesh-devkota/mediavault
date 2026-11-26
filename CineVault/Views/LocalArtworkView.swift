import SwiftUI
import UIKit

@MainActor struct LocalArtworkView: View {
    let movie: Movie
    let path: String
    var wide = false
    @ObservedObject private var household = HouseholdStore.shared
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image, LibraryCollectionsStore.available(movie) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else { Color.clear }
        }
        .task(id: "\(movie.id)/\(path)/\(movie.source?.lastScanDate?.timeIntervalSince1970 ?? 0)/\(household.sessionToken)") {
            image = nil
            let session = household.sessionToken
            guard LibraryCollectionsStore.available(movie), let source = movie.source,
                  let config = try? source.config(), !config.isJellyfin,
                  let decoded = try? await PhotoImageLoader.shared.image(config: config, path: path, knownSize: 0,
                    maxPixelSize: wide ? 1920 : PhotoImageLoader.thumbnailPixels, revision: source.lastScanDate),
                  !Task.isCancelled, household.sessionIsCurrent(session), LibraryCollectionsStore.available(movie),
                  !source.isDeleted, (try? source.config()) == config else { return }
            image = decoded
        }
    }
}
