#if os(iOS)
import Foundation

enum AppleFilesError: LocalizedError {
    case tryFilesAgain, differentSelection, unsupportedSelection, shortRead

    var errorDescription: String? {
        switch self {
        case .tryFilesAgain: "Open the Files app and check access to the original files, then reconnect this source."
        case .differentSelection: "Choose the original folder or files to reconnect. To use a different selection, add a new source."
        case .unsupportedSelection: "Choose a folder or media files in Files. Choose files with distinct names."
        case .shortRead: "Files did not return the requested media data."
        }
    }
}

struct AppleFilesSelection: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let name: String
        let bookmark: Data
    }

    let directory: Bool
    let entries: [Entry]

    static func capture(_ urls: [URL], directory: Bool) throws -> Self {
        guard !urls.isEmpty, urls.count <= 128, !directory || urls.count == 1 else { throw AppleFilesError.unsupportedSelection }
        let entries = try urls.map { url -> Entry in
            guard url.startAccessingSecurityScopedResource() else { throw AppleFilesError.tryFilesAgain }
            defer { url.stopAccessingSecurityScopedResource() }
            let value = try AppleFilesSource.info(url)
            guard value.isDirectory == directory else { throw AppleFilesError.unsupportedSelection }
            return Entry(name: url.lastPathComponent,
                         bookmark: try url.bookmarkData(options: .minimalBookmark,
                                                       includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        guard Set(entries.map { Data($0.name.utf8) }).count == entries.count else {
            throw AppleFilesError.unsupportedSelection
        }
        return Self(directory: directory, entries: entries)
    }
}

enum AppleFilesSource {
    private static let root = "."
    private static let changes = SourceChanges()

    private final class SourceChanges: @unchecked Sendable {
        private let lock = NSRecursiveLock()
        private var versions: [UUID: UUID] = [:]

        func current(id: UUID) -> UUID {
            lock.lock()
            defer { lock.unlock() }
            if let version = versions[id] { return version }
            let version = UUID()
            versions[id] = version
            return version
        }

        func update(_ id: UUID, action: () throws -> Void) throws {
            lock.lock()
            defer { lock.unlock() }
            try action()
            versions[id] = UUID()
        }
    }

    static func install(_ proposed: AppleFilesSelection, id: UUID, replacing: Bool) throws {
        try changes.update(id) {
            if replacing {
                let previous = try load(id)
                let identity = identities(proposed)
                guard previous.directory == proposed.directory,
                      !identity.isEmpty, identities(previous) == identity else { throw AppleFilesError.differentSelection }
            }
            let encoded = try JSONEncoder().encode(proposed)
            guard encoded.count < 512 * 1024 else { throw AppleFilesError.unsupportedSelection }
            try Keychain.set(encoded.base64EncodedString(), for: key(id))
        }
    }

    static func remove(_ id: UUID) throws {
        try changes.update(id) { try Keychain.delete(key(id)) }
    }
    static func isDirectory(_ id: UUID) throws -> Bool { try load(id).directory }

    static func transport(_ config: SourceConfig) throws -> CloudFileTransport {
        let version = changes.current(id: config.id)
        let selected = try load(config.id)
        return transport(selected, stillConnected: {
            guard changes.current(id: config.id) == version else { throw AppleFilesError.tryFilesAgain }
        })
    }

    static func transport(_ selection: AppleFilesSelection,
                          stillConnected: @escaping CloudFileTransport.Permission = {},
                          resolve: @escaping @Sendable (Data) throws -> URL = { try resolveBookmark($0) },
                          acquire: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
                          release: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) -> CloudFileTransport {
        CloudFileTransport(rootID: root, children: { parent, permission in
            let authorized: CloudFileTransport.Permission = { try permission(); try stillConnected() }
            return try await perform(authorized) {
                if selection.directory {
                    guard let entry = selection.entries.first else { throw AppleFilesError.unsupportedSelection }
                    return try withResource(entry, resolve: resolve, acquire: acquire, release: release) { folder in
                        let directory = try path(parent, in: folder)
                        return try coordinate(directory) { readable in
                            let listing = try FileManager.default.contentsOfDirectory(at: readable,
                                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                options: [.skipsHiddenFiles])
                            guard listing.count <= 20_000 else { throw CloudFileError.invalidListing }
                            return listing.compactMap { url in
                                guard let value = try? info(url) else { return nil }
                                let name = url.lastPathComponent
                                let id = parent == root ? name : parent + "/" + name
                                return .init(id: id, name: name, isDirectory: value.isDirectory, size: value.size)
                            }
                        }
                    }
                }
                guard parent == root else { throw CloudFileError.invalidPath }
                return try selection.entries.map { entry in
                    try withResource(entry, resolve: resolve, acquire: acquire, release: release) { url in
                        let value = try info(url)
                        guard !value.isDirectory else { throw CloudFileError.invalidPath }
                        return .init(id: entry.name, name: entry.name, isDirectory: false, size: value.size)
                    }
                }
            }
        }, rangeRead: { item, position, count, permission in
            let authorized: CloudFileTransport.Permission = { try permission(); try stillConnected() }
            return try await perform(authorized) {
                let entry = selection.directory ? selection.entries.first : selection.entries.first {
                    WebDAVAddress.sameComponent($0.name, item.id)
                }
                guard let entry else { throw CloudFileError.invalidPath }
                return try withResource(entry, resolve: resolve, acquire: acquire, release: release) { target in
                    let file = selection.directory ? try path(item.id, in: target) : target
                    return try coordinate(file) { readable in
                        try authorized()
                        let value = try info(readable)
                        guard !value.isDirectory, value.size == item.size else { throw AppleFilesError.shortRead }
                        let handle = try FileHandle(forReadingFrom: readable)
                        defer { try? handle.close() }
                        try handle.seek(toOffset: UInt64(position))
                        let bytes = try handle.read(upToCount: count)
                        guard let bytes, bytes.count == count else { throw AppleFilesError.shortRead }
                        return bytes
                    }
                }
            }
        })
    }

    static func info(_ url: URL) throws -> (isDirectory: Bool, size: Int64) {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
            throw AppleFilesError.unsupportedSelection
        }
        return (values.isDirectory == true, Int64(values.fileSize ?? 0))
    }

    private static func identities(_ selection: AppleFilesSelection) -> Set<Data> {
        let values = selection.entries.compactMap { try? resolveBookmark($0.bookmark).standardizedFileURL.absoluteString }
        return values.count == selection.entries.count ? Set(values.map { Data($0.utf8) }) : []
    }

    private static func path(_ relative: String, in folder: URL) throws -> URL {
        guard try info(folder).isDirectory else { throw CloudFileError.invalidPath }
        if relative == root { return folder }
        guard WebDAVAddress.contains(relative, within: ""), relative.utf8.count <= 4096 else { throw CloudFileError.invalidPath }
        var location = folder
        let parts = relative.components(separatedBy: "/")
        for (index, name) in parts.enumerated() {
            location.appendPathComponent(name)
            let value = try info(location)
            if index + 1 < parts.count && !value.isDirectory { throw CloudFileError.invalidPath }
        }
        return location
    }

    private static func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private static func withResource<T>(_ entry: AppleFilesSelection.Entry,
                                        resolve: (Data) throws -> URL, acquire: (URL) -> Bool,
                                        release: (URL) -> Void, read: (URL) throws -> T) throws -> T {
        let url = try resolve(entry.bookmark)
        guard acquire(url) else { throw AppleFilesError.tryFilesAgain }
        defer { release(url) }
        return try read(url)
    }

    private static func coordinate<T>(_ url: URL, operation: @escaping (URL) throws -> T) throws -> T {
        var error: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { readable in
            result = Result { try operation(readable) }
        }
        if let error { throw error }
        guard let result else { throw AppleFilesError.tryFilesAgain }
        return try result.get()
    }

    private static func perform<T: Sendable>(_ permission: @escaping CloudFileTransport.Permission,
                                             operation: @escaping @Sendable () throws -> T) async throws -> T {
        let work = Task.detached(priority: .userInitiated) {
            try permission()
            let result = try operation()
            try permission()
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private static func load(_ id: UUID) throws -> AppleFilesSelection {
        guard let raw = try Keychain.get(key(id)), let data = Data(base64Encoded: raw),
              let selection = try? JSONDecoder().decode(AppleFilesSelection.self, from: data) else {
            throw AppleFilesError.tryFilesAgain
        }
        return selection
    }

    private static func key(_ id: UUID) -> String { "apple-files-source-\(id.uuidString)" }
}
#endif
