import AMSMB2
import CineVaultCore
import Foundation

struct RemoteFile: Sendable {
    let path: String
    let size: Int64
}

struct NASDirectoryEntry: Sendable, Identifiable {
    let name: String
    let isDirectory: Bool
    var id: String { name }
}

struct ScanProgress: Sendable {
    let files: [RemoteFile]
    let found: Int
    let folders: Int
}
typealias MediaScanReporter = @MainActor @Sendable (ScanProgress) async throws -> Void

enum SMBError: LocalizedError, Equatable {
    case invalidServer
    case invalidFileSize
    case invalidByteRange
    case sourceChanged
    case unexpectedEndOfFile

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Invalid server address."
        case .invalidFileSize: return "The NAS file is empty or its size could not be read."
        case .invalidByteRange: return "The requested NAS file byte range is invalid."
        case .sourceChanged: return "The NAS source changed during the operation. Retry."
        case .unexpectedEndOfFile: return "The NAS file ended unexpectedly. Rescan the source and retry."
        }
    }
}

/// Owns one connected SMB2Manager per source and exposes the few operations the app needs.
actor SMBService {
    static let shared = SMBService()

    /// libsmb2 also maps logon failures to connection-refused; that code alone is not an auth signal.
    nonisolated static func isAuthenticationFailure(_ error: Error) -> Bool {
        var current = error as NSError
        for _ in 0..<8 {
            if current.domain == NSPOSIXErrorDomain {
                if current.code == Int(POSIXErrorCode.EACCES.rawValue) { return true }
                let detail = [NSLocalizedDescriptionKey, NSLocalizedFailureReasonErrorKey]
                    .compactMap { current.userInfo[$0] as? String }.joined(separator: " ").lowercased()
                if ["status_logon_failure", "status_wrong_password", "status_access_denied",
                    "0xc000006d", "0xc000006a", "0xc0000022"].contains(where: detail.contains) { return true }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? Error else { break }
            current = underlying as NSError
        }
        return false
    }

    private let timeout: TimeInterval?
    private let connect: (SMB2Manager, String) async throws -> Void
    private let makeCloud: (CloudFileProvider, SourceConfig) throws -> CloudFileTransport
    private var managers: [SourceConfig: SMB2Manager] = [:]
    private var generations: [UUID: UInt64] = [:]

    init(timeout: TimeInterval? = nil,
         cloudTransport: @escaping (CloudFileProvider, SourceConfig) throws -> CloudFileTransport = { provider, config in
             switch provider {
             case .appleFiles:
             #if os(iOS)
             return try AppleFilesSource.transport(config)
             #else
             throw CloudFileError.invalidPath
             #endif
             }
         },
         connect: @escaping (SMB2Manager, String) async throws -> Void = { manager, share in
             try await manager.connectShare(name: share)
         }) {
        self.timeout = timeout
        self.makeCloud = cloudTransport
        self.connect = connect
    }

    private func manager(for config: SourceConfig) async throws -> SMB2Manager {
        if let existing = managers[config] { return existing }
        let generation = generations[config.id, default: 0]
        let credential = config.username.isEmpty ? nil
            : URLCredential(user: config.username, password: config.password, persistence: .forSession)
        guard let url = config.serverURL, let manager = SMB2Manager(url: url, credential: credential) else {
            throw SMBError.invalidServer
        }
        if let timeout { manager.timeout = timeout }
        try await connect(manager, config.share)
        try Task.checkCancellation()
        guard generations[config.id, default: 0] == generation else { throw SMBError.sourceChanged }
        if let existing = managers[config] { return existing }
        managers[config] = manager
        return manager
    }

    func reset(_ config: SourceConfig) async {
        generations[config.id, default: 0] &+= 1
        // In-flight operations retain their manager until their file handles close.
        // Disconnecting here frees those handles underneath AMSMB2's reads.
        // Its context disconnects on deinit after the final operation releases it.
        managers.removeValue(forKey: config)
    }

    func reset(sourceID: UUID) async {
        generations[sourceID, default: 0] &+= 1
        let stale = managers.filter { $0.key.id == sourceID }
        for config in stale.keys { managers.removeValue(forKey: config) }
    }

    /// Retries once with a fresh connection (NAS may drop idle sessions).
    func withManager<T>(_ config: SourceConfig, _ body: (SMB2Manager) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let generation = generations[config.id, default: 0]
        func checkSource() throws {
            try Task.checkCancellation()
            guard generations[config.id, default: 0] == generation else { throw SMBError.sourceChanged }
        }
        var usedManager: SMB2Manager?
        do {
            let manager = try await manager(for: config)
            usedManager = manager
            try checkSource()
            let result = try await body(manager)
            try checkSource()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch SMBError.sourceChanged {
            throw SMBError.sourceChanged
        } catch {
            try checkSource()
            if let usedManager, managers[config] === usedManager {
                // Other reads may still be using this connection.
                managers.removeValue(forKey: config)
            }
            try checkSource()
            let manager = try await manager(for: config)
            try checkSource()
            let result = try await body(manager)
            try checkSource()
            return result
        }
    }

    func testConnection(_ config: SourceConfig) async throws {
        await reset(config)
        if config.isWebDAV || config.cloudFileProvider != nil { _ = try await listEntries(config); return }
        _ = try await withManager(config) { try await $0.contentsOfDirectory(atPath: config.rootPath) }
    }

    func listShares(_ config: SourceConfig) async throws -> [String] {
        try Task.checkCancellation()
        let credential = config.username.isEmpty ? nil
            : URLCredential(user: config.username, password: config.password, persistence: .forSession)
        guard let url = config.serverURL, let manager = SMB2Manager(url: url, credential: credential) else {
            throw SMBError.invalidServer
        }
        if let timeout { manager.timeout = timeout }
        let shares = try await manager.listShares().map { $0.name }
        try Task.checkCancellation()
        return shares.filter { !$0.isEmpty && !$0.hasSuffix("$") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Lists direct child directories for setup without recursively scanning media.
    func listFolders(_ config: SourceConfig) async throws -> [String] {
        if config.isWebDAV || config.cloudFileProvider != nil {
            return try await listEntries(config).filter(\.isDirectory).map(\.name)
        }
        return try await withManager(config) { manager in
            let entries = try await manager.contentsOfDirectory(atPath: config.rootPath)
            return entries.compactMap { entry -> String? in
                guard (entry[.isDirectoryKey] as? Bool) == true,
                      let name = entry[.nameKey] as? String,
                      !name.isEmpty, name != ".", name != ".." else { return nil }
                return name
            }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    /// Read-only entries for the source folder and exclusion pickers.
    func listEntries(_ config: SourceConfig, directory: String? = nil) async throws -> [NASDirectoryEntry] {
        if config.isWebDAV || config.cloudFileProvider != nil {
            let entries = try await exactPathEntries(config, path: directory ?? config.rootPath)
            return entries.map { NASDirectoryEntry(name: String($0.path.split(separator: "/").last ?? ""), isDirectory: $0.isDirectory) }
        }
        let path: String
        if let directory {
            guard let safe = SubtitleFile.safePath(directory, within: config.rootPath, allowRoot: true),
                  !config.excludesDirectory(safe) else { throw SMBError.sourceChanged }
            path = safe
        } else { path = config.rootPath }
        return try await withManager(config) { manager in
            let entries = try await manager.contentsOfDirectory(atPath: path)
            return entries.compactMap { entry -> NASDirectoryEntry? in
                guard let name = entry[.nameKey] as? String, !name.isEmpty, name != ".", name != "..",
                      !name.contains("/"), !name.contains("\\") else { return nil }
                return NASDirectoryEntry(name: name, isDirectory: (entry[.isDirectoryKey] as? Bool) == true)
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    /// Recursively lists indexable video files below the source's root folder.
    func scanVideos(_ config: SourceConfig) async throws -> [RemoteFile] {
        if config.isWebDAV || config.cloudFileProvider != nil {
            return try await scanExactPaths(config, videosOnly: true) { _ in }
        }
        return try await withManager(config) { manager in
            var results: [RemoteFile] = []
            var pending = [config.rootPath]
            while let dir = pending.popLast() {
                try Task.checkCancellation()
                if config.excludesDirectory(dir) { continue }
                let entries = try await manager.contentsOfDirectory(atPath: dir)
                for entry in entries {
                    guard let name = entry[.nameKey] as? String else { continue }
                    let path = (entry[.pathKey] as? String) ?? (dir as NSString).appendingPathComponent(name)
                    if (entry[.isDirectoryKey] as? Bool) == true {
                        if !VideoFile.shouldSkipDirectory(name: name), !MediaFile.shouldSkipDirectory(name: name),
                           !config.excludesDirectory(path) { pending.append(path) }
                    } else {
                        let size = (entry[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
                        if !config.excludesFile(path), MediaFile.shouldIndex(path: path, size: size),
                           VideoFile.shouldIndex(path: path, size: size) {
                            if MediaFile.requiresContentCheck(path: path) {
                                let prefix = try await manager.contents(atPath: path, range: 0..<UInt64(min(size, 1024)), progress: nil)
                                guard MediaFile.isTransportStream(prefix: prefix) else { continue }
                            }
                            results.append(RemoteFile(path: path, size: size))
                        }
                    }
                }
            }
            return results
        }
    }

    /// Reports each directory/batch so large libraries become usable before traversal finishes.
    func scanMedia(_ config: SourceConfig, onProgress: MediaScanReporter) async throws -> [RemoteFile] {
        if config.isWebDAV || config.cloudFileProvider != nil { return try await scanExactPaths(config, onProgress: onProgress) }
        return try await withManager(config) { manager in
            var results: [RemoteFile] = []
            var pending = [config.rootPath]
            var folders = 0
            while let dir = pending.popLast() {
                try Task.checkCancellation()
                if config.excludesDirectory(dir) { continue }
                let entries = try await manager.contentsOfDirectory(atPath: dir)
                var batch: [RemoteFile] = []
                for entry in entries {
                    try Task.checkCancellation()
                    guard let name = entry[.nameKey] as? String, name != ".", name != ".." else { continue }
                    let path = (entry[.pathKey] as? String) ?? (dir as NSString).appendingPathComponent(name)
                    if (entry[.isDirectoryKey] as? Bool) == true {
                        if !MediaFile.shouldSkipDirectory(name: name), !config.excludesDirectory(path) { pending.append(path) }
                    } else {
                        let size = (entry[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
                        if !config.excludesFile(path), MediaFile.shouldIndex(path: path, size: size) {
                            if MediaFile.requiresContentCheck(path: path) {
                                let prefix = try await manager.contents(atPath: path, range: 0..<UInt64(min(size, 1024)), progress: nil)
                                guard MediaFile.isTransportStream(prefix: prefix) else { continue }
                            }
                            let file = RemoteFile(path: path, size: size)
                            results.append(file); batch.append(file)
                            if batch.count >= 100 {
                                try await onProgress(ScanProgress(files: batch, found: results.count, folders: folders))
                                batch.removeAll()
                            }
                        }
                    }
                }
                folders += 1
                try await onProgress(ScanProgress(files: batch, found: results.count, folders: folders))
            }
            return results
        }
    }

    func read(_ config: SourceConfig, path: String, offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length >= 0, Int64(length) <= Int64.max - offset else {
            throw SMBError.invalidByteRange
        }
        guard length > 0 else { return Data() }
        if let provider = config.cloudFileProvider {
            guard !config.excludesFile(path), WebDAVAddress.contains(path, within: config.rootPath) else {
                throw CloudFileError.invalidPath
            }
            return try await withCloud(config, provider: provider, path: path) { transport, check in
                try await transport.read(path, offset: offset, length: length, check: check)
            }
        }
        if config.isWebDAV {
            guard WebDAVAddress.contains(path, within: config.rootPath), !config.excludesFile(path) else { throw WebDAVError.invalidPath }
            return try await withWebDAV(config) { try await $0.read(path, offset: offset, length: length) }
        }
        return try await withManager(config) { manager in
            let lower = UInt64(offset)
            return try await manager.contents(atPath: path, range: lower..<(lower + UInt64(length)), progress: nil)
        }
    }

    func fileSize(_ config: SourceConfig, path: String) async throws -> Int64 {
        if let provider = config.cloudFileProvider {
            guard !config.excludesFile(path), WebDAVAddress.contains(path, within: config.rootPath) else {
                throw CloudFileError.invalidPath
            }
            return try await withCloud(config, provider: provider, path: path) { transport, check in
                try await transport.fileSize(path, check: check)
            }
        }
        if config.isWebDAV {
            guard WebDAVAddress.contains(path, within: config.rootPath), !config.excludesFile(path) else { throw WebDAVError.invalidPath }
            return try await withWebDAV(config) { try await $0.fileSize(path) }
        }
        return try await withManager(config) { manager in
            let attributes = try await manager.attributesOfItem(atPath: path)
            guard let size = (attributes[.fileSizeKey] as? NSNumber)?.int64Value, size > 0 else {
                throw SMBError.invalidFileSize
            }
            return size
        }
    }

    private func withWebDAV<T>(_ config: SourceConfig, operation: (WebDAVTransport) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let generation = generations[config.id, default: 0]
        let transport = try WebDAVTransport(address: WebDAVAddress(config.host), username: config.username, password: config.password)
        let result = try await operation(transport)
        try Task.checkCancellation()
        guard generations[config.id, default: 0] == generation else { throw SMBError.sourceChanged }
        return result
    }

    private func exactPathEntries(_ config: SourceConfig, path: String) async throws -> [RemoteDirectoryEntry] {
        guard WebDAVAddress.contains(path, within: config.rootPath, allowRoot: true),
              !config.excludesDirectory(path) else {
            if config.cloudFileProvider != nil { throw CloudFileError.invalidPath }
            throw WebDAVError.invalidPath
        }
        if let provider = config.cloudFileProvider {
            return try await withCloud(config, provider: provider, path: path) { transport, check in
                try await transport.list(path, check: check)
            }
        }
        return try await withWebDAV(config) { try await $0.list(path) }
    }

    private func withCloud<T>(_ config: SourceConfig, provider: CloudFileProvider, path: String,
                              operation: (CloudFileTransport, CloudFileTransport.Permission) async throws -> T) async throws -> T {
        let generation = generations[config.id, default: 0]
        let household = HouseholdStore.shared
        let session = household.sessionToken
        let check: CloudFileTransport.Permission = {
            try Task.checkCancellation()
            guard household.sessionIsCurrent(session),
                  household.allowsPath(sourceID: config.id, path: path, caseSensitive: true) else {
                throw HouseholdError.denied
            }
        }
        try check()
        let transport = try makeCloud(provider, config)
        let result = try await operation(transport, check)
        try check()
        guard generations[config.id, default: 0] == generation else { throw SMBError.sourceChanged }
        return result
    }

    private func scanExactPaths(_ config: SourceConfig, videosOnly: Bool = false, onProgress: MediaScanReporter) async throws -> [RemoteFile] {
        let generation = generations[config.id, default: 0]
        let isCloud = config.cloudFileProvider != nil
        let household = HouseholdStore.shared
        let session = household.sessionToken
        func check() throws {
            try Task.checkCancellation()
            guard generations[config.id, default: 0] == generation else { throw SMBError.sourceChanged }
            if isCloud {
                guard household.sessionIsCurrent(session), household.isAdmin else { throw HouseholdError.denied }
            }
        }
        var pending = [config.rootPath]
        var results: [RemoteFile] = []
        var folders = 0
        var entryCount = 0
        while let directory = pending.popLast() {
            try check()
            let entries = try await exactPathEntries(config, path: directory)
            try check()
            if isCloud {
                guard folders < 20_000, entries.count <= 200_000 - entryCount else { throw CloudFileError.invalidListing }
                entryCount += entries.count
            }
            var batch: [RemoteFile] = []
            folders += 1
            for entry in entries {
                let name = String(entry.path.split(separator: "/").last ?? "")
                if entry.isDirectory {
                    if !MediaFile.shouldSkipDirectory(name: name), !config.excludesDirectory(entry.path),
                       !videosOnly || !VideoFile.shouldSkipDirectory(name: name) {
                        pending.append(entry.path)
                    }
                    continue
                }
                guard !config.excludesFile(entry.path), MediaFile.shouldIndex(path: entry.path, size: entry.size),
                      !videosOnly || VideoFile.shouldIndex(path: entry.path, size: entry.size) else { continue }
                if MediaFile.requiresContentCheck(path: entry.path) {
                    let prefix = try await read(config, path: entry.path, offset: 0, length: Int(min(entry.size, 1024)))
                    guard MediaFile.isTransportStream(prefix: prefix) else { continue }
                }
                let file = RemoteFile(path: entry.path, size: entry.size)
                results.append(file)
                batch.append(file)
                if batch.count == 100 {
                    try check()
                    try await onProgress(ScanProgress(files: batch, found: results.count, folders: folders))
                    batch.removeAll()
                }
            }
            try check()
            try await onProgress(ScanProgress(files: batch, found: results.count, folders: folders))
        }
        try check()
        return results
    }

}
