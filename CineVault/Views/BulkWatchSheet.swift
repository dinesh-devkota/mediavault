import Foundation
import SwiftData
import SwiftUI

private struct BulkWatchRequest: Identifiable {
    let id = UUID()
    let movieIDs: [UUID]
    let includeHidden: Bool
}

struct BulkWatchControl: View {
    private enum Target: Hashable { case button, result }
    let title: String
    let scope: String
    let movies: [Movie]
    var startsSelected = true
    var groupShows = false
    var includeHidden = false
    @State private var request: BulkWatchRequest?
    @State private var message: String?
    @FocusState private var focused: Target?

    private var eligible: [Movie] { movies.filter { BulkWatchStatus.isEligible($0, includeHidden: includeHidden) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(title) {
                request = BulkWatchRequest(movieIDs: eligible.map(\.id), includeHidden: includeHidden)
            }
            .disabled(eligible.isEmpty)
            .focused($focused, equals: .button)
            .accessibilityIdentifier("bulk-watch-open")
            if let message {
                Text(message).font(.callout).foregroundStyle(CinemaTheme.secondaryText)
                    .focusable().focused($focused, equals: .result)
                    .accessibilityIdentifier("bulk-watch-result")
            }
        }
        .sheet(item: $request, onDismiss: {
            if eligible.isEmpty && message == nil { message = "No available files in this selection." }
            focused = eligible.isEmpty ? .result : .button
        }) { request in
            BulkWatchSheet(movieIDs: request.movieIDs, scope: scope,
                           startsSelected: startsSelected, groupShows: groupShows,
                           includeHidden: request.includeHidden) { message = $0 }
        }
        .onChange(of: scope) { _, _ in message = nil }
    }
}

struct BulkWatchSheet: View {
    private struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String
        let movies: [Movie]
        var ids: Set<UUID> { Set(movies.map(\.id)) }
    }

    let movieIDs: [UUID]
    let scope: String
    let groupShows: Bool
    let includeHidden: Bool
    let completion: (String) -> Void
    @Query private var library: [Movie]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var playbackServices: PlaybackServices
    @State private var selected: Set<UUID>
    @State private var error: String?
    @FocusState private var focus: String?

    init(movieIDs: [UUID], scope: String, startsSelected: Bool, groupShows: Bool,
         includeHidden: Bool,
         completion: @escaping (String) -> Void) {
        self.movieIDs = movieIDs
        self.scope = scope
        self.groupShows = groupShows
        self.includeHidden = includeHidden
        self.completion = completion
        _selected = State(initialValue: startsSelected ? Set(movieIDs) : [])
    }

    private var available: [Movie] {
        let byID = Dictionary(library.filter { BulkWatchStatus.isEligible($0, includeHidden: includeHidden) }.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        return movieIDs.compactMap { byID[$0] }
    }
    private var selectedMovies: [Movie] { available.filter { selected.contains($0.id) } }
    private var rows: [Row] {
        if groupShows {
            return CollectionRowItem.grouped(available, limit: .max).map { item in
                switch item {
                case .movie(let movie): return row(movie)
                case .show(let show):
                    return Row(id: show.id, title: show.title,
                               detail: "\(show.episodes.count) episode files in these results", movies: show.episodes)
                }
            }
        }
        return available.map(row)
    }
    private func row(_ movie: Movie) -> Row {
        let episode = movie.episodeInfo.map { String(format: "S%02dE%02d · ", $0.season, $0.episode) } ?? ""
        return Row(id: movie.id.uuidString, title: episode + movie.title,
                   detail: "\(movie.householdWatched ? "Watched" : "Unwatched") · \(movie.source?.name ?? "Library") · \(movie.filePath)",
                   movies: [movie])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Watched status").font(.largeTitle.bold())
                    Text(scope).font(.title3).foregroundStyle(CinemaTheme.secondaryText)
                }
                Spacer()
                Button("Cancel") { dismiss() }.focused($focus, equals: "done")
                    .accessibilityIdentifier("bulk-watch-done")
            }
            Text("\(selectedMovies.count) of \(available.count) files selected")
                .accessibilityIdentifier("bulk-watch-count")
            CinemaTheme.actionLayout {
                Button("Select all results") { selected = Set(available.map(\.id)) }
                    .disabled(available.isEmpty).focused($focus, equals: "all")
                    .accessibilityIdentifier("bulk-watch-all")
                Button("Clear") { selected.removeAll() }.disabled(selected.isEmpty)
                    .focused($focus, equals: "clear")
                Button("Mark watched (\(selectedMovies.count))") { apply(watched: true) }
                    .disabled(selectedMovies.isEmpty).focused($focus, equals: "watched")
                    .accessibilityIdentifier("bulk-watch-watched")
                Button("Mark unwatched (\(selectedMovies.count))") { apply(watched: false) }
                    .disabled(selectedMovies.isEmpty).focused($focus, equals: "unwatched")
                    .accessibilityIdentifier("bulk-watch-unwatched")
            }
            Text("Changing watched status clears saved playback positions for the selected files.")
                .font(.callout).foregroundStyle(CinemaTheme.secondaryText)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(rows) { row in
                        Button { toggle(row) } label: {
                            HStack(spacing: 18) {
                                Image(systemName: row.ids.isSubset(of: selected) ? "checkmark.square.fill" :
                                        row.ids.isDisjoint(with: selected) ? "square" : "minus.square.fill")
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(row.title).font(.headline).lineLimit(1)
                                    Text(row.detail).font(.caption).lineLimit(2)
                                }
                                Spacer()
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .focused($focus, equals: row.id)
                        .accessibilityIdentifier("bulk-watch-row-\(row.id)")
                        .accessibilityValue(row.ids.isSubset(of: selected) ? "Selected" : "Not selected")
                        .accessibilityAddTraits(row.ids.isSubset(of: selected) ? .isSelected : [])
                        .onTVMove { direction in
                            if direction == .right && !selectedMovies.isEmpty { focus = "watched" }
                        }
                    }
                }.padding(18)
            }
        }
        .padding(CinemaTheme.featuredInset)
        .frame(maxWidth: 1550)
        .task {
            await Task.yield()
            focus = selectedMovies.isEmpty ? "all" : "watched"
        }
        .onChange(of: available.map(\.id)) { _, ids in
            selected.formIntersection(ids)
            if ids.isEmpty { focus = "done" }
            // A source edit can remove the focused row while this sheet is open.
            if let focus, focus != "done", !["all", "clear", "watched", "unwatched"].contains(focus),
               !rows.contains(where: { $0.id == focus }) { self.focus = "done" }
        }
        .onTVExit { dismiss() }
    }

    private func toggle(_ row: Row) {
        if row.ids.isSubset(of: selected) { selected.subtract(row.ids) }
        else { selected.formUnion(row.ids) }
    }

    private func apply(watched: Bool) {
        do {
            let result = try BulkWatchStatus.apply(selectedMovies, watched: watched,
                includeHidden: includeHidden,
                reset: playbackServices.resetProgress, save: { try context.save() })
            let text = "Marked \(result.updatedIDs.count) files \(watched ? "watched" : "unwatched")."
            completion(text)
            if result.failedCount == 0 { dismiss() }
            else {
                selected.subtract(result.updatedIDs)
                error = "\(text) \(result.failedCount) files could not be updated. Try again."
            }
        } catch {
            self.error = "Could not save watched status. Please try again."
            #if CINEVAULT_COMMERCIAL
            self.error = "Could not save watched status. Some saved playback positions may have been cleared. Please try again."
            #endif
        }
    }
}
