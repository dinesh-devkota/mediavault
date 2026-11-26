import Foundation

struct DropboxSourceBinding: Equatable, Codable, Sendable {
    let appKey: String
    let accountID: String
    let folderID: String

    init(appKey: String, accountID: String, folderID: String) throws {
        guard DropboxClient.isAppKey(appKey), DropboxClient.isAccountID(accountID),
              DropboxClient.isItemID(folderID) else { throw CloudFileError.accountChanged }
        self.appKey = appKey
        self.accountID = accountID
        self.folderID = folderID
    }

    init(_ config: SourceConfig) throws {
        guard config.cloudFileProvider == .dropbox else { throw CloudFileError.invalidPath }
        try self.init(appKey: config.host, accountID: config.username, folderID: config.share)
    }
}

actor DropboxAccountStore {
    static let shared = DropboxAccountStore()

    struct Grant: Codable, Sendable {
        let binding: DropboxSourceBinding
        let refresh: String

        func revoke() async -> Bool {
            do {
                let client = try DropboxClient(appKey: binding.appKey)
                let access = try await client.refresh(refresh)
                try await client.revoke(accessToken: access.access_token)
                return true
            } catch DropboxClientError.http(401) { return true }
            catch DropboxClientError.http(400) { return true }
            catch { return false }
        }
    }

    private struct Token {
        let value: String
        let expires: ContinuousClock.Instant
    }

    private struct Refresh {
        let id: UUID
        let worker: Task<String, Error>
    }

    private var epochs: [UUID: UUID] = [:]
    private var tokens: [UUID: Token] = [:]
    private var inflight: [UUID: Refresh] = [:]

    /// Only refresh credentials are written to Keychain. A prior grant can be retired separately.
    func install(_ credentials: DropboxClient.Credentials, binding: DropboxSourceBinding, id: UUID,
                 authorize: CloudFileTransport.Permission = {}) throws -> Grant? {
        guard credentials.account_id == binding.accountID, let refresh = credentials.refresh_token,
              DropboxClient.isToken(refresh) else { throw CloudFileError.needsSignIn }
        let access = try makeToken(credentials)
        let previous = try? stored(id)
        guard previous?.binding == nil || previous?.binding == binding else { throw CloudFileError.accountChanged }
        try authorize()
        let data = try JSONEncoder().encode(Grant(binding: binding, refresh: refresh))
        try Keychain.set(String(decoding: data, as: UTF8.self), for: key(id))
        invalidate(id)
        tokens[id] = access
        return previous?.refresh == refresh ? nil : previous
    }

    func isSaved(_ refresh: String, id: UUID) -> Bool {
        (try? stored(id))?.refresh == refresh
    }

    func remove(id: UUID) throws -> Grant? {
        let prior = try? stored(id)
        try Keychain.delete(key(id))
        invalidate(id)
        return prior
    }

    func authorized<Result: Sendable>(_ config: SourceConfig, client: DropboxClient,
                                      authorize: @escaping CloudFileTransport.Permission,
                                      operation: @Sendable (String) async throws -> Result) async throws -> Result {
        try authorize()
        let binding = try DropboxSourceBinding(config)
        guard let grant = try stored(config.id) else { throw CloudFileError.needsSignIn }
        guard grant.binding == binding else { throw CloudFileError.accountChanged }
        let epoch = epochs[config.id] ?? UUID()
        epochs[config.id] = epoch
        let access = try await token(grant: grant, id: config.id, epoch: epoch, client: client, authorize: authorize)
        try validate(config.id, epoch, authorize)
        let result: Result
        do { result = try await operation(access) }
        catch DropboxClientError.http(401) {
            try validate(config.id, epoch, authorize)
            if tokens[config.id]?.value == access { tokens.removeValue(forKey: config.id) }
            let retry = try await token(grant: grant, id: config.id, epoch: epoch, client: client, authorize: authorize)
            try validate(config.id, epoch, authorize)
            result = try await operation(retry)
        }
        try validate(config.id, epoch, authorize)
        return result
    }

    private func token(grant: Grant, id: UUID, epoch: UUID, client: DropboxClient,
                       authorize: @escaping CloudFileTransport.Permission) async throws -> String {
        try validate(id, epoch, authorize)
        if let access = tokens[id], access.expires > ContinuousClock.now.advanced(by: .seconds(30)) {
            return access.value
        }
        if let pending = inflight[id] { return try await pending.worker.value }
        let refreshID = UUID()
        let worker = Task {
            defer { if inflight[id]?.id == refreshID { inflight.removeValue(forKey: id) } }
            try validate(id, epoch, authorize)
            let credentials: DropboxClient.Credentials
            do { credentials = try await client.refresh(grant.refresh) }
            catch DropboxClientError.http(400) { throw CloudFileError.needsSignIn }
            try validate(id, epoch, authorize)
            if let account = credentials.account_id, account != grant.binding.accountID { throw CloudFileError.accountChanged }
            let access = try makeToken(credentials)
            tokens[id] = access
            return access.value
        }
        inflight[id] = Refresh(id: refreshID, worker: worker)
        return try await worker.value
    }

    private func makeToken(_ credentials: DropboxClient.Credentials) throws -> Token {
        guard DropboxClient.isToken(credentials.access_token), (1...86_400).contains(credentials.expires_in) else {
            throw DropboxClientError.invalidResponse
        }
        return Token(value: credentials.access_token,
                     expires: ContinuousClock.now.advanced(by: .seconds(credentials.expires_in)))
    }

    private func validate(_ id: UUID, _ epoch: UUID, _ authorize: CloudFileTransport.Permission) throws {
        try Task.checkCancellation()
        try authorize()
        guard epochs[id] == epoch else { throw CloudFileError.needsSignIn }
    }

    private func stored(_ id: UUID) throws -> Grant? {
        guard let value = try Keychain.get(key(id)) else { return nil }
        guard let grant = try? JSONDecoder().decode(Grant.self, from: Data(value.utf8)),
              DropboxClient.isToken(grant.refresh) else { throw CloudFileError.needsSignIn }
        return grant
    }

    private func invalidate(_ id: UUID) {
        epochs[id] = UUID()
        tokens.removeValue(forKey: id)
        inflight.removeValue(forKey: id)?.worker.cancel()
    }

    private func key(_ id: UUID) -> String { "dropbox-account-\(id.uuidString)" }
}

enum DropboxFileSource {
    static func transport(_ config: SourceConfig, account: DropboxAccountStore = .shared,
                          client: DropboxClient? = nil) throws -> CloudFileTransport {
        let binding = try DropboxSourceBinding(config)
        let api = try client ?? DropboxClient(appKey: binding.appKey)
        return CloudFileTransport(rootID: binding.folderID, children: { id, check in
            try await account.authorized(config, client: api, authorize: check) { token in
                try await items(client: api, folderID: id, access: token, authorize: check)
            }
        }, rangeRead: { item, offset, count, check in
            guard let revision = item.revision else { throw CloudFileError.invalidRange }
            return try await account.authorized(config, client: api, authorize: check) { token in
                try await api.read(fileID: item.id, offset: offset, length: count, accessToken: token,
                                   expectedSize: item.size, revision: revision, authorize: check)
            }
        })
    }

    static func items(client: DropboxClient, folderID: String?, access: String,
                      authorize: CloudFileTransport.Permission = {}) async throws -> [CloudFileTransport.Item] {
        if let folderID, !DropboxClient.isItemID(folderID) { throw CloudFileError.invalidPath }
        var result: [CloudFileTransport.Item] = []
        var visited = 0
        try await client.listFolder(path: folderID ?? "", accessToken: access, authorize: authorize) { page in
            guard page.count <= 20_000 - visited else { throw CloudFileError.invalidListing }
            visited += page.count
            for entry in page {
                guard let id = entry.id, DropboxClient.isItemID(id) else { continue }
                switch entry.kind {
                case "folder":
                    result.append(.init(id: id, name: entry.name, isDirectory: true, size: 0))
                case "file":
                    guard entry.downloadable, let size = entry.size, size > 0,
                          let revision = entry.revision, (9...128).contains(revision.utf8.count),
                          revision.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
                    else { continue }
                    result.append(.init(id: id, name: entry.name, isDirectory: false, size: size, revision: revision))
                default: continue
                }
            }
        }
        return CloudFileTransport.usableEntries(result)
    }
}
