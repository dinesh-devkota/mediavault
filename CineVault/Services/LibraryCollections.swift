import CineVaultCore
import Foundation
import Combine

struct MovieVersionGroup: Identifiable {
    let id: String
    let movies: [Movie]
    var representative: Movie { movies[0] }
}

enum MovieVersions {
    /// No title-only guesses: unknown years and unlike media kinds remain individual files.
    static func key(_ movie: Movie) -> String {
        guard movie.episodeInfo == nil, [.movie, .documentary].contains(movie.mediaKind) else { return "file:\(movie.id)" }
        if let id = movie.tmdbID { return "tmdb:\(id)" }
        guard let year = movie.year ?? movie.parsedYear, year > 0 else { return "file:\(movie.id)" }
        let title = TitleMatcher.normalize(movie.title)
        guard !title.isEmpty else { return "file:\(movie.id)" }
        return "title:\(title)|\(year)"
    }
    static func groups(_ movies: [Movie]) -> [MovieVersionGroup] {
        var order: [String] = [], grouped: [String: [Movie]] = [:]
        for movie in movies where !movie.isDeleted && !movie.isMissing && HouseholdStore.shared.allows(movie) && movie.source?.isIgnored(filePath: movie.filePath) != true {
            let key = key(movie)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(movie)
        }
        return order.compactMap { key in grouped[key].map { MovieVersionGroup(id: key, movies: $0) } }
    }
    static func label(_ movie: Movie) -> String {
        let file = movie.fileName.lowercased()
        var parts: [String] = []
        if let edition = movie.localEdition, !edition.isEmpty { parts.append(edition) }
        for (match, label) in [("director", "Director’s cut"), ("extended", "Extended"), ("theatrical", "Theatrical"), ("unrated", "Unrated"), ("remaster", "Remastered")] {
            if parts.isEmpty && file.contains(match) { parts.append(label); break }
        }
        for (match, label) in [("2160p", "4K"), ("4k", "4K"), ("1080p", "1080p"), ("720p", "720p"), ("480p", "480p")] {
            if file.range(of: "(?<![a-z0-9])\(match)(?![a-z0-9])", options: .regularExpression) != nil { parts.append(label); break }
        }
        let ext = (movie.filePath as NSString).pathExtension.uppercased()
        if !ext.isEmpty { parts.append(ext) }
        if movie.fileSize > 0 { parts.append(ByteCountFormatter.string(fromByteCount: movie.fileSize, countStyle: .file)) }
        return parts.isEmpty ? "Original file" : parts.joined(separator: " · ")
    }
}

struct NamedMediaCollection: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var movieIDs: [UUID]
}

enum LibraryCollectionError: LocalizedError {
    case name, locked, full, unavailable
    var errorDescription: String? {
        switch self {
        case .name: return "Choose a unique collection name between 1 and 80 characters."
        case .locked: return "Unlock your profile and try again."
        case .full: return "The collection limit has been reached. Remove an unused collection first."
        case .unavailable: return "These titles are no longer available to this profile."
        }
    }
}

/// Personal collections live alongside the active profile's library preferences, not the shared catalog.
@MainActor
final class LibraryCollectionsStore: ObservableObject {
    static let shared: LibraryCollectionsStore = {
        #if DEBUG
        if LibraryFeaturesPreview.isEnabled { return LibraryCollectionsStore(defaults: LibraryFeaturesPreview.defaults) }
        #endif
        return LibraryCollectionsStore()
    }()
    @Published private(set) var revision = 0
    private let household: HouseholdStore
    private let suppliedDefaults: UserDefaults?
    private static let storageKey = "library.customCollections.v1"
    init(defaults: UserDefaults? = nil, household: HouseholdStore = .shared) { suppliedDefaults = defaults; self.household = household }
    private var defaults: UserDefaults { suppliedDefaults ?? household.preferenceDefaults }
    var collections: [NamedMediaCollection] {
        guard !household.isLocked, let data = defaults.data(forKey: Self.storageKey), data.count <= 4 * 1024 * 1024,
              let records = try? JSONDecoder().decode([NamedMediaCollection].self, from: data) else { return [] }
        return records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func create(name: String, movies: [Movie], session: UUID) throws -> UUID {
        try authorize(session)
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var records = collections
        guard !value.isEmpty, value.count <= 80, !records.contains(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame }) else { throw LibraryCollectionError.name }
        guard records.count < 500 else { throw LibraryCollectionError.full }
        let eligible = movies.filter { Self.available($0, household: household) }
        guard movies.isEmpty || !eligible.isEmpty else { throw LibraryCollectionError.unavailable }
        let id = UUID()
        records.append(NamedMediaCollection(id: id, name: value, movieIDs: Array(Set(eligible.map(\.id)))))
        try save(records, session: session)
        return id
    }
    func add(_ movies: [Movie], to id: UUID, session: UUID) throws {
        try authorize(session)
        var records = collections
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw LibraryCollectionError.unavailable }
        let ids = movies.filter { Self.available($0, household: household) }.map(\.id)
        guard !ids.isEmpty else { throw LibraryCollectionError.unavailable }
        records[index].movieIDs = Array(Set(records[index].movieIDs + ids))
        try save(records, session: session)
    }
    func remove(movieIDs: Set<UUID>, from id: UUID, session: UUID) throws {
        try authorize(session)
        var records = collections
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].movieIDs.removeAll { movieIDs.contains($0) }
        try save(records, session: session)
    }
    func rename(_ id: UUID, name: String, session: UUID) throws {
        try authorize(session)
        var records = collections
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80, !records.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(value) == .orderedSame }),
              let index = records.firstIndex(where: { $0.id == id }) else { throw LibraryCollectionError.name }
        records[index].name = value
        try save(records, session: session)
    }
    func delete(_ id: UUID, session: UUID) throws { try save(collections.filter { $0.id != id }, session: session) }
    private func authorize(_ session: UUID) throws {
        guard !household.isLocked, household.sessionIsCurrent(session) else { throw LibraryCollectionError.locked }
    }
    private func save(_ records: [NamedMediaCollection], session: UUID) throws {
        try authorize(session)
        let data = try JSONEncoder().encode(records)
        guard data.count <= 4 * 1024 * 1024 else { throw LibraryCollectionError.full }
        defaults.set(data, forKey: Self.storageKey); revision += 1
    }
    static func available(_ movie: Movie, household: HouseholdStore = .shared) -> Bool {
        guard !movie.isDeleted, !movie.isMissing, !movie.isHidden, !MediaFile.isPhoto(path: movie.filePath), household.allows(movie) else { return false }
        guard let source = movie.source else { return true }
        return !source.isDeleted && PhotoLocation.contains(path: movie.filePath, root: source.rootPath, caseSensitive: source.caseSensitivePaths) && !source.isIgnored(filePath: movie.filePath)
    }
}

struct VisibleMediaCollection: Identifiable {
    let id: String
    let name: String
    let movies: [Movie]
    let customID: UUID?
    var titleCount: Int { Set(movies.map { movie in
        if let episode = movie.episodeInfo { return movie.seriesTMDBID.map { "show:\($0)" } ?? "show:\(TitleMatcher.normalize(movie.seriesTitle ?? episode.seriesTitle))" }
        return MovieVersions.key(movie)
    }).count }
}

enum MediaCollections {
    @MainActor static func visible(library: [Movie], custom: [NamedMediaCollection]) -> [VisibleMediaCollection] {
        let available = library.filter { LibraryCollectionsStore.available($0) }
        var groups = custom.map { record in
            VisibleMediaCollection(id: "custom:\(record.id)", name: record.name,
                movies: available.filter { record.movieIDs.contains($0.id) }, customID: record.id)
        }
        let franchise = Dictionary(grouping: available.filter { $0.episodeInfo == nil && [.movie, .documentary].contains($0.mediaKind) && $0.collectionName?.isEmpty == false }, by: {
            $0.collectionID.map { "tmdb:\($0)" } ?? "local:\(TitleMatcher.normalize($0.collectionName ?? ""))"
        })
        groups += franchise.compactMap { key, movies in
            guard MovieVersions.groups(movies).count > 1, let name = movies.first?.collectionName else { return nil }
            return VisibleMediaCollection(id: key, name: name, movies: movies, customID: nil)
        }
        return groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
