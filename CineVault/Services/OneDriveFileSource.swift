import Foundation

struct OneDriveSourceBinding: Sendable, Equatable, Codable {
    let clientID: String
    let driveID: String
    let folderID: String

    init(clientID: String, driveID: String, folderID: String) throws {
        guard let client = UUID(uuidString: clientID),
              OneDriveClient.isItemID(driveID), OneDriveClient.isItemID(folderID) else {
            throw CloudFileError.accountChanged
        }
        self.clientID = client.uuidString.lowercased()
        self.driveID = driveID
        self.folderID = folderID
    }

    init(_ config: SourceConfig) throws {
        guard config.cloudFileProvider == .oneDrive else { throw CloudFileError.invalidPath }
        try self.init(clientID: config.host, driveID: config.username, folderID: config.share)
    }
}

/// Stores one refresh credential per local source. Access credentials remain in memory.
actor OneDriveAccountStore {
    static let shared = OneDriveAccountStore()

    struct Storage: Sendable {
        var read: @Sendable (String) throws -> String?
        var write: @Sendable (String, String) throws -> Void
        var delete: @Sendable (String) throws -> Void

        static let keychain = Storage(read: { try Keychain.get($0) },
                                      write: { try Keychain.set($0, for: $1) },
                                      delete: { try Keychain.delete($0) })
    }

    private struct Record: Codable {
        let binding: OneDriveSourceBinding
        let refresh: String
    }

    private struct Token {
        let value: String
        let expires: ContinuousClock.Instant
    }

    private struct Refresh {
        let id: UUID
        let task: Task<String, Error>
    }

    private let storage: Storage
    private var epochs: [UUID: UUID] = [:]
    private var accessTokens: [UUID: Token] = [:]
    private var refreshes: [UUID: Refresh] = [:]

    init(storage: Storage = .keychain) { self.storage = storage }

    func install(_ credentials: OneDriveClient.Credentials, binding: OneDriveSourceBinding, id: UUID) throws {
        guard let refresh = credentials.refresh_token, OneDriveClient.isToken(refresh) else { throw CloudFileError.needsSignIn }
        let token = try token(from: credentials)
        try save(Record(binding: binding, refresh: refresh), id: id)
        invalidate(id)
        accessTokens[id] = token
    }

    func remove(id: UUID) throws {
        invalidate(id)
        try storage.delete(accountKey(id))
    }

    func authorized<Result: Sendable>(_ config: SourceConfig, client: OneDriveClient,
                            operation: @Sendable (String) async throws -> Result) async throws -> Result {
        let binding = try OneDriveSourceBinding(config)
        let id = config.id
        let epoch = epochs[id] ?? UUID()
        epochs[id] = epoch
        let record = try load(id)
        guard record.binding == binding else { throw CloudFileError.accountChanged }
        let currentToken = try await access(for: record, id: id, epoch: epoch, client: client)
        try check(id, epoch)
        do {
            let result = try await operation(currentToken)
            try check(id, epoch)
            return result
        } catch OneDriveError.rejected(401) {
            try check(id, epoch)
            if accessTokens[id]?.value == currentToken { accessTokens.removeValue(forKey: id) }
            let next = try await access(for: load(id), id: id, epoch: epoch, client: client)
            try check(id, epoch)
            let result = try await operation(next)
            try check(id, epoch)
            return result
        }
    }

    private func access(for record: Record, id: UUID, epoch: UUID, client: OneDriveClient) async throws -> String {
        if let token = accessTokens[id], token.expires > ContinuousClock.now.advanced(by: .seconds(30)) {
            return token.value
        }
        if let active = refreshes[id] { return try await active.task.value }
        let refreshID = UUID()
        let task = Task {
            defer { if refreshes[id]?.id == refreshID { refreshes.removeValue(forKey: id) } }
            let credentials = try await client.refresh(record.refresh)
            try check(id, epoch)
            let token = try self.token(from: credentials)
            let account = try await client.identifyDrive(accessToken: token.value)
            try check(id, epoch)
            guard account == record.binding.driveID else { throw CloudFileError.accountChanged }
            let updated = credentials.refresh_token ?? record.refresh
            guard OneDriveClient.isToken(updated) else { throw OneDriveError.invalidResponse }
            if updated != record.refresh { try save(Record(binding: record.binding, refresh: updated), id: id) }
            accessTokens[id] = token
            return token.value
        }
        refreshes[id] = Refresh(id: refreshID, task: task)
        return try await task.value
    }

    private func token(from credentials: OneDriveClient.Credentials) throws -> Token {
        guard OneDriveClient.isToken(credentials.access_token),
              (1...86_400).contains(credentials.expires_in) else { throw OneDriveError.invalidResponse }
        return Token(value: credentials.access_token,
                     expires: ContinuousClock.now.advanced(by: .seconds(credentials.expires_in)))
    }

    private func check(_ id: UUID, _ epoch: UUID) throws {
        try Task.checkCancellation()
        guard epochs[id] == epoch else { throw CloudFileError.needsSignIn }
    }

    private func invalidate(_ id: UUID) {
        epochs[id] = UUID()
        accessTokens.removeValue(forKey: id)
        refreshes.removeValue(forKey: id)?.task.cancel()
    }

    private func load(_ id: UUID) throws -> Record {
        guard let data = try storage.read(accountKey(id)),
              let record = try? JSONDecoder().decode(Record.self, from: Data(data.utf8)),
              OneDriveClient.isToken(record.refresh) else { throw CloudFileError.needsSignIn }
        return record
    }

    private func save(_ record: Record, id: UUID) throws {
        let encoded = try JSONEncoder().encode(record)
        try storage.write(String(decoding: encoded, as: UTF8.self), accountKey(id))
    }

    private func accountKey(_ id: UUID) -> String { "onedrive-account-\(id.uuidString)" }
}

enum OneDriveFileSource {
    static func transport(_ config: SourceConfig, account: OneDriveAccountStore = .shared, client: OneDriveClient? = nil) throws -> CloudFileTransport {
        let binding = try OneDriveSourceBinding(config)
        let graph = try client ?? OneDriveClient(clientID: binding.clientID)
        return CloudFileTransport(rootID: binding.folderID, children: { id, check in
            try await account.authorized(config, client: graph) { access in
                try await folders(client: graph, driveID: binding.driveID, folderID: id, access: access, authorize: check)
            }
        }, rangeRead: { item, offset, length, check in
            try await account.authorized(config, client: graph) { access in
                try await graph.read(fileID: item.id, offset: offset, length: length, accessToken: access,
                                     expectedSize: item.size, authorize: check)
            }
        })
    }

    static func folders(client: OneDriveClient, driveID: String, folderID: String, access: String,
                        authorize: CloudFileTransport.Permission = {}) async throws -> [CloudFileTransport.Item] {
        var entries: [CloudFileTransport.Item] = []
        var read = 0
        try await client.listChildren(folderID: folderID, accessToken: access, driveID: driveID, authorize: authorize) { page in
            try Task.checkCancellation()
            guard page.count <= 20_000 - read else { throw CloudFileError.invalidListing }
            read += page.count
            entries.append(contentsOf: page.compactMap(\.localItem))
        }
        return entries
    }
}
