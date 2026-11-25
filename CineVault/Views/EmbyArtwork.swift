import ImageIO
import SwiftUI

/// Load artwork within the active household and source session; credentials stay in request headers.
struct EmbyArtwork: View {
    let movie: Movie
    var series = false
    let width: Int
    @ObservedObject private var household = HouseholdStore.shared
    @State private var loaded: (Request, UIImage)?

    private struct Request: Equatable {
        let session: UUID
        let sourceID: UUID
        let endpoint: String
        let movieID: UUID
        let itemID: String
        let width: Int
    }

    private var request: Request? {
        guard household.allows(movie), LibrarySearch.isAvailable(movie),
              let source = movie.source, source.isEmby else { return nil }
        let id = series ? movie.providerSeriesID : try? EmbySourceConnection.itemID(for: movie.filePath)
        guard let id, EmbySourceConnection.validID(id) else { return nil }
        return Request(session: household.sessionToken, sourceID: source.id, endpoint: source.host,
                       movieID: movie.id, itemID: id, width: width)
    }

    var body: some View {
        let current = request
        Group {
            if let loaded, loaded.0 == current {
                Image(uiImage: loaded.1).resizable().aspectRatio(contentMode: .fill)
            } else { Color.clear }
        }.task(id: current) {
            loaded = nil
            guard let current, request == current, household.sessionIsCurrent(current.session),
                  let source = movie.source else { return }
            do {
                let config = try source.config()
                let connection = try EmbySourceConnection(config: config)
                let data = try await connection.client.primaryImage(connection.account, itemID: current.itemID, width: current.width)
                try Task.checkCancellation()
                guard request == current, household.sessionIsCurrent(current.session), try source.config() == config else { return }
                guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: current.width * 2,
                      ] as CFDictionary) else { return }
                loaded = (current, UIImage(cgImage: thumbnail))
            } catch {
                // No artwork is a normal state for personal media.
            }
        }
    }
}
