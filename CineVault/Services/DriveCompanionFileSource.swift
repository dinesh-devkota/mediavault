import CineVaultCore
import Foundation
import SwiftData

/// A paired connection is a flat snapshot of selected Drive files, not a grant to their parents.
enum DriveCompanionFileSource {
    static let share = "selected"
    private static let rootID = ":mediavault:drive-selection:"
    private static let access = Access()

    struct Binding: Codable, Equatable, Sendable {
        let endpoint: URL
        let token: String
        let files: [DriveCompanionFile]
    }

    private struct Identity: Hashable {
        let id: String
        let name: Data
        let parentId: String?
    }

    private final class Access: @unchecked Sendable {
        let lock = NSLock()
        var versions: [UUID: UUID] = [:]

        func current(_ id: UUID) -> UUID {
            if let version = versions[id] { return version }
            let version = UUID()
            versions[id] = version
            return version
        }
    }

    static func validated(_ files: [DriveCompanionFile]) throws -> [DriveCompanionFile] {
        guard (1...512).contains(files.count), files.allSatisfy({
            !$0.id.isEmpty && $0.id != rootID && $0.size > 0
        }), CloudFileTransport.usableEntries(files.map(item)).count == files.count else {
            throw CloudFileError.invalidListing
        }
        return files
    }

    static func sameSelection(_ first: [DriveCompanionFile], _ second: [DriveCompanionFile]) -> Bool {
        func identities(_ files: [DriveCompanionFile]) -> Set<Identity> {
            Set(files.map { Identity(id: $0.id, name: Data($0.name.utf8), parentId: $0.parentId) })
        }
        return first.count == second.count && identities(first) == identities(second)
    }

    static func transport(_ config: SourceConfig) throws -> CloudFileTransport {
        let (binding, version) = try snapshot(config)
        let client = try DriveCompanionClient(endpoint: binding.endpoint)
        return try transport(files: binding.files, stillConnected: {
            try access.lock.withLock {
                guard access.current(config.id) == version else { throw SMBError.sourceChanged }
            }
        }, read: { file, offset, length in
            try await client.read(file: file, token: binding.token, offset: offset, length: length)
        })
    }

    static func transport(files: [DriveCompanionFile], stillConnected: @escaping CloudFileTransport.Permission = {},
                          read: @escaping @Sendable (DriveCompanionFile, Int64, Int) async throws -> Data) throws -> CloudFileTransport {
        let selection = try validated(files)
        let indexed = Dictionary(uniqueKeysWithValues: selection.map { ($0.id, $0) })
        let entries = selection.map(item)
        return CloudFileTransport(rootID: rootID, children: { id, permission in
            try permission()
            try stillConnected()
            guard id == rootID else { throw CloudFileError.invalidPath }
            return entries
        }, rangeRead: { entry, offset, length, permission in
            try permission()
            try stillConnected()
            guard let file = indexed[entry.id], WebDAVAddress.sameComponent(file.name, entry.name) else {
                throw CloudFileError.invalidPath
            }
            let data = try await read(file, offset, length)
            try permission()
            try stillConnected()
            return data
        })
    }

    static func siblingNames(for video: String, in files: [DriveCompanionFile]) -> Set<Data> {
        guard let parent = files.first(where: { WebDAVAddress.sameComponent($0.name, video) })?.parentId,
              !parent.isEmpty else { return [] }
        return Set(files.lazy.filter { $0.parentId == parent }.map { Data($0.name.utf8) })
    }

    static func subtitleEntries(_ entries: [NASDirectoryEntry], videoPath: String,
                                config: SourceConfig) throws -> [NASDirectoryEntry] {
        let (binding, _) = try snapshot(config)
        let siblings = siblingNames(for: videoPath, in: binding.files)
        return entries.filter { siblings.contains(Data($0.name.utf8)) }
    }

    static func saved(_ id: UUID) throws -> Binding? {
        try access.lock.withLock {
            try Keychain.get(key(id)).map(decode)
        }
    }

    static func save(_ binding: Binding, id: UUID, replacing previous: Binding?,
                     commit: () throws -> Void) throws {
        let encoded = try JSONEncoder().encode(binding)
        guard encoded.count <= 512 * 1024 else { throw CloudFileError.invalidListing }
        try access.lock.withLock {
            let original = try Keychain.get(key(id))
            guard try original.map(decode) == previous else { throw SMBError.sourceChanged }
            try set(encoded.base64EncodedString(), original: original, id: id, commit: commit)
        }
    }

    static func remove(_ id: UUID, commit: () throws -> Void) throws -> Binding? {
        try access.lock.withLock {
            let original = try Keychain.get(key(id))
            try set(nil, original: original, id: id, commit: commit)
            return original.flatMap { try? decode($0) }
        }
    }

    private static func set(_ value: String?, original: String?, id: UUID, commit: () throws -> Void) throws {
        let account = key(id)
        if let value { try Keychain.set(value, for: account) }
        else { try Keychain.delete(account) }
        // Revoke any live operation, including if the database save fails and rolls back.
        access.versions[id] = UUID()
        do { try commit() }
        catch {
            if let original { try Keychain.set(original, for: account) }
            else { try Keychain.delete(account) }
            throw error
        }
    }

    private static func snapshot(_ config: SourceConfig) throws -> (Binding, UUID) {
        guard config.cloudFileProvider == .googleDrive, config.share == share,
              config.rootPath.isEmpty else { throw CloudFileError.invalidPath }
        return try access.lock.withLock {
            guard let value = try Keychain.get(key(config.id)) else { throw CloudFileError.needsSignIn }
            let binding = try decode(value)
            guard binding.endpoint.absoluteString == config.host else { throw CloudFileError.accountChanged }
            return (binding, access.current(config.id))
        }
    }

    private static func decode(_ value: String) throws -> Binding {
        guard let data = Data(base64Encoded: value), data.count <= 512 * 1024 else {
            throw CredentialError.invalidData
        }
        return try JSONDecoder().decode(Binding.self, from: data)
    }

    private static func key(_ id: UUID) -> String { "google-drive-companion-\(id.uuidString)" }
    private static func item(_ file: DriveCompanionFile) -> CloudFileTransport.Item {
        .init(id: file.id, name: file.name, isDirectory: false, size: file.size)
    }
}

@MainActor
enum DriveCompanionSourceStore {
    static func create(name: String, endpoint: URL, connection: DriveCompanionConnection,
                       context: ModelContext, authorize: () throws -> Void) async throws -> MediaSource {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CloudFileError.invalidPath }
        let binding = try await confirm(endpoint, connection, authorize: authorize)
        let source = MediaSource(name: name, host: endpoint.absoluteString, share: DriveCompanionFileSource.share,
                                 rootPath: "", username: "")
        source.sourceProtocol = CloudFileProvider.googleDrive.rawValue
        try requireOwner(authorize)
        try DriveCompanionFileSource.save(binding, id: source.id, replacing: nil) {
            context.insert(source)
            try save(context)
        }
        return source
    }

    static func reconnect(source: MediaSource, endpoint: URL, connection: DriveCompanionConnection,
                          context: ModelContext, authorize: () throws -> Void) async throws {
        try requireOwner(authorize)
        guard source.cloudFileProvider == .googleDrive, source.host == endpoint.absoluteString,
              let previous = try DriveCompanionFileSource.saved(source.id),
              previous.endpoint == endpoint,
              DriveCompanionFileSource.sameSelection(previous.files, connection.files) else {
            throw CloudFileError.accountChanged
        }
        let binding = try await confirm(endpoint, connection, authorize: authorize)
        try requireOwner(authorize)
        try DriveCompanionFileSource.save(binding, id: source.id, replacing: previous) {}
        await SMBService.shared.reset(sourceID: source.id)
        if binding.token != previous.token { revokeLater(previous) }
    }

    static func remove(source: MediaSource, context: ModelContext, authorize: () throws -> Void) async throws {
        try requireOwner(authorize)
        guard source.cloudFileProvider == .googleDrive else { throw CloudFileError.invalidPath }
        let id = source.id
        let previous = try DriveCompanionFileSource.remove(id) {
            context.delete(source)
            try save(context)
        }
        await SMBService.shared.reset(sourceID: id)
        if let previous { revokeLater(previous) }
    }

    static func abandon(endpoint: URL, connection: DriveCompanionConnection, protecting source: MediaSource?) async {
        if let source {
            do {
                if let old = try DriveCompanionFileSource.saved(source.id),
                   old.endpoint == endpoint, old.token == connection.token { return }
            } catch { return }
        }
        try? await DriveCompanionClient(endpoint: endpoint).disconnect(token: connection.token)
    }

    private static func confirm(_ endpoint: URL, _ connection: DriveCompanionConnection,
                                authorize: () throws -> Void) async throws -> DriveCompanionFileSource.Binding {
        try requireOwner(authorize)
        let expected = try DriveCompanionFileSource.validated(connection.files)
        let client = try DriveCompanionClient(endpoint: endpoint)
        let catalog = try await client.catalog(token: connection.token)
        let files = try DriveCompanionFileSource.validated(catalog)
        try requireOwner(authorize)
        guard DriveCompanionFileSource.sameSelection(expected, files) else { throw CloudFileError.accountChanged }
        return .init(endpoint: endpoint, token: connection.token, files: files)
    }

    private static func save(_ context: ModelContext) throws {
        do { try context.save() }
        catch { context.rollback(); throw error }
    }

    private static func requireOwner(_ authorize: () throws -> Void) throws {
        try Task.checkCancellation()
        guard HouseholdStore.shared.isAdmin else { throw HouseholdError.denied }
        try authorize()
    }

    private static func revokeLater(_ binding: DriveCompanionFileSource.Binding) {
        Task { try? await DriveCompanionClient(endpoint: binding.endpoint).disconnect(token: binding.token) }
    }
}
