import Foundation

enum PlexAccountError: LocalizedError {
    case invalidIdentity, invalidResponse, status(Int)

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "MediaVault could not identify this device to Plex."
        case .invalidResponse: return "Plex returned an invalid linking or server response."
        case .status(404): return "The Plex link code expired. Request a new code."
        case .status(let status): return "Plex returned HTTP \(status)."
        }
    }
}

private final class PlexRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct PlexAccountClient: Sendable {
    #if os(iOS)
    static let platform = "iOS"
    static let deviceName = "iPhone"
    #else
    static let platform = "tvOS"
    static let deviceName = "Apple TV"
    #endif

    struct LinkCode: Decodable, Sendable {
        let id: Int
        let code: String
        let expiresIn: Int
    }

    private struct LinkStatus: Decodable { let authToken: String? }

    struct Server: Decodable, Sendable, Identifiable {
        struct Connection: Decodable, Sendable {
            let uri: URL
            let local: Bool
            let relay: Bool
        }
        let name: String
        let clientIdentifier: String
        let provides: String
        let accessToken: String?
        let connections: [Connection]
        var id: String { clientIdentifier }

        var secureConnections: [Connection] {
            connections.filter {
                guard let url = URLComponents(url: $0.uri, resolvingAgainstBaseURL: false) else { return false }
                return url.scheme == "https" && url.host?.isEmpty == false && url.user == nil &&
                    url.password == nil && url.query == nil && url.fragment == nil &&
                    (url.percentEncodedPath.isEmpty || url.percentEncodedPath == "/")
            }
        }
    }

    let linkPage = URL(string: "https://plex.tv/link")!
    typealias Exchange = @Sendable (URLRequest, Int, Int) async throws -> (Data, HTTPURLResponse)
    private let deviceID: String
    private let transport: Exchange
    private static let endpoint = URL(string: "https://plex.tv/api/v2")!
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: PlexRedirectDelegate(), delegateQueue: nil)
    }()

    init(deviceID: String, exchange: Exchange? = nil) throws {
        guard UUID(uuidString: deviceID) != nil else { throw PlexAccountError.invalidIdentity }
        self.deviceID = deviceID
        transport = exchange ?? { request, limit, status in
            try await Self.exchange(request, limit: limit, expectedStatus: status)
        }
    }

    func beginLink() async throws -> LinkCode {
        let data = try await send("pins", method: "POST", query: [URLQueryItem(name: "strong", value: "false")])
        let pin = try JSONDecoder().decode(LinkCode.self, from: data)
        guard pin.id > 0, (1...32).contains(pin.code.utf8.count), pin.expiresIn > 0,
              pin.code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw PlexAccountError.invalidResponse
        }
        return pin
    }

    func pollLink(_ pin: LinkCode) async throws -> String? {
        guard pin.id > 0 else { throw PlexAccountError.invalidResponse }
        let data = try await send("pins/\(pin.id)", query: [URLQueryItem(name: "code", value: pin.code)])
        let status = try JSONDecoder().decode(LinkStatus.self, from: data)
        guard let token = status.authToken, !token.isEmpty else { return nil }
        guard Self.isValidToken(token) else { throw PlexAccountError.invalidResponse }
        return token
    }

    func listServers(accountToken: String) async throws -> [Server] {
        let data = try await send("resources", token: accountToken, query: [
            URLQueryItem(name: "includeHttps", value: "1"),
            URLQueryItem(name: "includeRelay", value: "1"),
        ])
        return try JSONDecoder().decode([Server].self, from: data).filter { server in
            server.provides.split(separator: ",").contains("server") &&
                server.accessToken?.isEmpty == false && !server.secureConnections.isEmpty
        }
    }

    private func send(_ path: String, method: String = "GET", token: String? = nil,
                      query: [URLQueryItem] = []) async throws -> Data {
        let url = path.split(separator: "/").reduce(Self.endpoint) { $0.appendingPathComponent(String($1)) }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PlexAccountError.invalidResponse }
        if !query.isEmpty { parts.queryItems = query }
        guard let target = parts.url else { throw PlexAccountError.invalidResponse }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MediaVault", forHTTPHeaderField: "X-Plex-Product")
        request.setValue(Self.platform, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(Self.deviceName, forHTTPHeaderField: "X-Plex-Device")
        request.setValue(deviceID, forHTTPHeaderField: "X-Plex-Client-Identifier")
        if let token {
            guard Self.isValidToken(token) else {
                throw PlexAccountError.invalidResponse
            }
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
        let (data, _) = try await transport(request, 4 * 1024 * 1024, 200)
        return data
    }

    static func isValidToken(_ token: String) -> Bool {
        (1...4096).contains(token.utf8.count) && token.utf8.allSatisfy { (33...126).contains($0) }
    }

    static func exchange(_ request: URLRequest, limit: Int, expectedStatus: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= Int64(limit) else {
            throw PlexAccountError.invalidResponse
        }
        let isCreated = expectedStatus == 200 && request.httpMethod == "POST" && http.statusCode == 201
        guard http.statusCode == expectedStatus || isCreated else {
            throw PlexAccountError.status(http.statusCode)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw PlexAccountError.invalidResponse }
            data.append(byte)
        }
        return (data, http)
    }
}
