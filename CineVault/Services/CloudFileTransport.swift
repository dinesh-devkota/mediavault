import CineVaultCore
import Foundation

enum CloudFileProvider: String, Hashable, Sendable {
    case oneDrive = "onedrive"
    case dropbox

    var title: String {
        switch self {
        case .oneDrive: "OneDrive"
        case .dropbox: "Dropbox"
        }
    }
}

enum CloudFileError: LocalizedError, Equatable {
    case invalidPath, invalidListing, needsSignIn, accountChanged, invalidRange

    var errorDescription: String? {
        switch self {
        case .invalidPath: "This file or folder is unavailable within the connected library."
        case .invalidListing: "The cloud provider returned an invalid folder listing."
        case .needsSignIn: "Open Sources and reconnect this account."
        case .accountChanged: "Reconnect with the account and folder originally linked to this source."
        case .invalidRange: "The provider did not return the requested file range. Rescan and try again."
        }
    }
}

struct RemoteDirectoryEntry: Equatable, Sendable {
    let path: String
    let isDirectory: Bool
    let size: Int64
}

/// A provider receives identifiers obtained from a fresh listing beneath the selected root.
struct CloudFileTransport: Sendable {
    struct Item: Equatable, Sendable {
        let id: String
        let name: String
        let isDirectory: Bool
        let size: Int64
        let revision: String?

        init(id: String, name: String, isDirectory: Bool, size: Int64, revision: String? = nil) {
            self.id = id
            self.name = name
            self.isDirectory = isDirectory
            self.size = size
            self.revision = revision
        }
    }

    typealias ListedChildren = @Sendable (String, Permission) async throws -> [Item]
    typealias RangeRead = @Sendable (Item, Int64, Int, Permission) async throws -> Data
    typealias Permission = @Sendable () throws -> Void

    let rootID: String
    let children: ListedChildren
    let rangeRead: RangeRead

    func list(_ path: String, check: @escaping Permission) async throws -> [RemoteDirectoryEntry] {
        let folderID = try await resolve(path, folder: true, check: check)?.id ?? rootID
        return try await descendants(of: folderID, check: check).map { item in
            RemoteDirectoryEntry(path: path.isEmpty ? item.name : path + "/" + item.name,
                                 isDirectory: item.isDirectory, size: item.size)
        }
    }

    func fileSize(_ path: String, check: @escaping Permission) async throws -> Int64 {
        guard let item = try await resolve(path, folder: false, check: check), item.size > 0 else {
            throw SMBError.invalidFileSize
        }
        return item.size
    }

    func read(_ path: String, offset: Int64, length: Int, check: @escaping Permission) async throws -> Data {
        guard let item = try await resolve(path, folder: false, check: check),
              offset >= 0, offset <= item.size, (1...8 * 1024 * 1024).contains(length),
              Int64(length) <= item.size - offset else { throw CloudFileError.invalidRange }
        try check()
        let bytes = try await rangeRead(item, offset, length, check)
        try check()
        guard bytes.count == length else { throw CloudFileError.invalidRange }
        return bytes
    }

    private func resolve(_ path: String, folder: Bool, check: @escaping Permission) async throws -> Item? {
        try check()
        guard path.utf8.count <= 4096,
              WebDAVAddress.contains(path, within: "", allowRoot: folder) else { throw CloudFileError.invalidPath }
        if path.isEmpty { return nil }
        let components = path.components(separatedBy: "/")
        guard components.count <= 64 else { throw CloudFileError.invalidPath }
        var parent = rootID
        var ancestors = Set([parent])
        for (index, part) in components.enumerated() {
            let last = index == components.count - 1
            let items = try await descendants(of: parent, check: check)
            guard let match = items.first(where: { WebDAVAddress.sameComponent($0.name, part) }),
                  match.isDirectory == (!last || folder), ancestors.insert(match.id).inserted else {
                throw CloudFileError.invalidPath
            }
            if last { return match }
            parent = match.id
        }
        throw CloudFileError.invalidPath
    }

    private func descendants(of folderID: String, check: @escaping Permission) async throws -> [Item] {
        try check()
        let items = try await children(folderID, check)
        try check()
        guard items.count <= 20_000 else { throw CloudFileError.invalidListing }
        return Self.usableEntries(items).filter { $0.id != folderID && $0.id != rootID }
    }

    static func usableEntries(_ items: [Item]) -> [Item] {
        let safe = items.filter {
            !$0.id.isEmpty && !$0.name.contains("/") && $0.name.utf8.count <= 255 &&
                $0.size >= 0 && WebDAVAddress.contains($0.name, within: "")
        }
        // Do not resolve by display name when the provider has multiple matching entries.
        let counts = Dictionary(grouping: safe, by: { Data($0.name.utf8) })
        let ids = Dictionary(grouping: safe, by: \.id)
        return safe.filter { counts[Data($0.name.utf8)]?.count == 1 && ids[$0.id]?.count == 1 }
    }
}
