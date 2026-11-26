import Foundation

/// One selected Plex server and library. The stored credential is the server token.
struct PlexSourceConnection: Sendable {
    let client: PlexMediaClient
    let sectionID: String

    init(config: SourceConfig, exchange: PlexMediaClient.Exchange? = nil) throws {
        guard config.isPlex, Self.validServerID(config.username), PlexMediaClient.isNumericID(config.share),
              let origin = URL(string: config.host) else { throw PlexAccountError.invalidResponse }
        let connection = PlexAccountClient.Server.Connection(uri: origin, local: false, relay: false)
        let server = PlexAccountClient.Server(name: "", clientIdentifier: config.username, provides: "server",
                                             accessToken: config.password, connections: [connection])
        client = try PlexMediaClient(server: server, connection: connection, deviceID: config.id.uuidString, exchange: exchange)
        sectionID = config.share
    }

    static func validServerID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func supports(_ section: PlexMediaClient.Section) -> Bool {
        ["movie", "show", "photo"].contains(section.type)
    }

    static func connect(_ server: PlexAccountClient.Server, deviceID: UUID) async throws -> (PlexMediaClient, [PlexMediaClient.Section]) {
        guard validServerID(server.id) else { throw PlexAccountError.invalidResponse }
        let secure = server.secureConnections
        let direct = Array((secure.filter { !$0.relay && $0.local } + secure.filter { !$0.relay && !$0.local }).prefix(6))
        for connection in direct {
            try Task.checkCancellation()
            do {
                let client = try PlexMediaClient(server: server, connection: connection, deviceID: deviceID.uuidString)
                try await client.verifyIdentity()
                return (client, try await client.libraries().filter(Self.supports))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Plex may advertise separate LAN and remote addresses for the same server.
            }
        }
        throw PlexSourceError.serverUnavailable
    }

    static func itemID(for path: String, photo: Bool) throws -> String {
        let prefix = photo ? "PlexPhotos/" : "PlexVideo/"
        let suffix = photo ? ".jpg" : ".mp4"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { throw PlexAccountError.invalidResponse }
        let id = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard PlexMediaClient.isNumericID(id) else { throw PlexAccountError.invalidResponse }
        return id
    }
}

enum PlexSourceError: LocalizedError {
    case serverUnavailable, linkExpired, selectionUnavailable, unsupportedVideo

    var errorDescription: String? {
        switch self {
        case .serverUnavailable: return "MediaVault could not verify a direct HTTPS connection to this Plex server."
        case .linkExpired: return "This Plex link code expired. Request a new code."
        case .selectionUnavailable: return "The linked account does not have access to this Plex library."
        case .unsupportedVideo: return "Plex did not offer a compatible direct-play file for this Apple TV."
        }
    }
}
