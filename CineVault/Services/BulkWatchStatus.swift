import CineVaultCore
import Foundation
import SwiftData

@MainActor
enum BulkWatchStatus {
    struct Result {
        let updatedIDs: Set<UUID>
        let failedCount: Int
    }

    static func isEligible(_ movie: Movie, includeHidden: Bool = false) -> Bool {
        guard HouseholdStore.shared.allows(movie) else { return false }
        guard !movie.isDeleted, !movie.isMissing, includeHidden || !movie.isHidden,
              VideoFile.isVideo(path: movie.filePath),
              MediaFile.shouldIndex(path: movie.filePath, size: max(1, movie.fileSize)) else { return false }
        guard let source = movie.source else { return true }
        return !source.isDeleted && PhotoLocation.contains(path: movie.filePath, root: source.rootPath, caseSensitive: source.caseSensitivePaths)
            && !source.isIgnored(filePath: movie.filePath)
    }

    /// One synchronous main-actor save prevents a scan or player callback from interleaving.
    /// Secure resume records use the existing commercial reset path and can fail per file.
    static func apply(_ movies: [Movie], watched: Bool, includeHidden: Bool = false, reset: (Movie) -> Bool,
                      save: () throws -> Void) throws -> Result {
        var seen: Set<UUID> = []
        let eligible = movies.filter { isEligible($0, includeHidden: includeHidden) && seen.insert($0.id).inserted }
        let previous = eligible.map { ($0, $0.householdWatched, $0.householdPosition) }
        var updated: Set<UUID> = []
        for movie in eligible {
            if reset(movie) {
                movie.householdWatched = watched
                updated.insert(movie.id)
            }
        }
        do {
            if !updated.isEmpty { try save() }
        } catch {
            // Do not roll back unrelated pending metadata or scanner changes in this context.
            for (movie, oldWatched, oldPosition) in previous {
                movie.householdWatched = oldWatched
                movie.householdPosition = oldPosition
            }
            throw error
        }
        return Result(updatedIDs: updated, failedCount: eligible.count - updated.count)
    }
}
