import Foundation

struct DriveCompanionPairing: Decodable, Equatable, Sendable {
    let id: String
    let secret: String
    let verificationUrl: URL
    let code: String
    let expiresIn: Int
}

struct DriveCompanionFile: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let size: Int64
    let mimeType: String
    let parentId: String?
}

struct DriveCompanionConnection: Decodable, Equatable, Sendable {
    let token: String
    let files: [DriveCompanionFile]
}

enum DriveCompanionError: LocalizedError, Equatable {
    case invalidEndpoint, invalidResponse, invalidRange, pairingExpired, reconnectRequired, unavailable
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The configured Google Drive companion address is invalid."
        case .invalidResponse: "The Google Drive companion returned an unexpected response."
        case .invalidRange: "The Google Drive companion could not return the requested part of this file."
        case .pairingExpired: "This pairing code expired. Start a new connection."
        case .reconnectRequired: "Open Sources and reconnect this Google Drive source."
        case .unavailable: "The Google Drive companion could not be reached. Try again."
        case .http(429): "The Google Drive companion is busy. Wait a moment and try again."
        case .http: "The Google Drive companion could not complete the request. Try again."
        }
    }
}

private final class DriveCompanionRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The TV sends one-source companion grants to the configured HTTPS origin. Google credentials stay with the companion.
struct DriveCompanionClient: Sendable {
    private struct PollResult: Decodable {
        let status: String
        let connection: DriveCompanionConnection?
    }

    private struct Catalog: Decodable {
        let files: [DriveCompanionFile]
    }

    private static let jsonLimit = 512 * 1024
    private static let rangeLimit = 8 * 1024 * 1024
    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: DriveCompanionRedirectDelegate(), delegateQueue: nil)
    }()

    static var configuredEndpoint: URL? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["MEDIA_VAULT_DRIVE_COMPANION_URL"] {
            return endpoint(from: override)
        }
        #endif
        return endpoint(from: Bundle.main.object(forInfoDictionaryKey: "MediaVaultDriveCompanionURL") as? String)
    }

    private let base: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession? = nil) throws {
        guard let base = Self.endpoint(from: endpoint.absoluteString) else { throw DriveCompanionError.invalidEndpoint }
        self.base = base
        self.session = session ?? Self.defaultSession
    }

    func beginPairing() async throws -> DriveCompanionPairing {
        let request = try makeRequest(path: "v1/pairings", method: "POST")
        let pairing: DriveCompanionPairing = try await json(request, status: 201)
        try validate(pairing)
        return pairing
    }

    func poll(_ pairing: DriveCompanionPairing) async throws -> DriveCompanionConnection? {
        try validate(pairing)
        let request = try makeRequest(path: "v1/pairings/\(pairing.id)", token: pairing.secret)
        do {
            let result: PollResult = try await json(request)
            switch (result.status, result.connection) {
            case ("pending", nil): return nil
            case ("approved", let connection?):
                guard Self.identifier(connection.token, length: 32...128) else { throw DriveCompanionError.invalidResponse }
                try Self.validate(connection.files)
                return connection
            default: throw DriveCompanionError.invalidResponse
            }
        } catch DriveCompanionError.http(let code) where [401, 404, 410].contains(code) {
            throw DriveCompanionError.pairingExpired
        }
    }

    func cancel(_ pairing: DriveCompanionPairing) async throws {
        try validate(pairing)
        let request = try makeRequest(path: "v1/pairings/\(pairing.id)", method: "DELETE", token: pairing.secret)
        _ = try await send(request, limit: 0, accepting: [204, 404, 410], ignoreBody: true)
    }

    func catalog(token: String) async throws -> [DriveCompanionFile] {
        let request = try makeRequest(path: "v1/connection", token: token)
        do {
            let result: Catalog = try await json(request)
            try Self.validate(result.files)
            return result.files
        } catch DriveCompanionError.http(let code) where code == 401 || code == 403 {
            throw DriveCompanionError.reconnectRequired
        }
    }

    func disconnect(token: String) async throws {
        let request = try makeRequest(path: "v1/connection", method: "DELETE", token: token)
        _ = try await send(request, limit: 0, accepting: [204, 401, 404, 410], ignoreBody: true)
    }

    func read(file: DriveCompanionFile, token: String, offset: Int64, length: Int) async throws -> Data {
        guard Self.identifier(file.id), offset >= 0, offset < file.size,
              (1...Self.rangeLimit).contains(length), Int64(length) <= file.size - offset else {
            throw DriveCompanionError.invalidRange
        }
        let end = offset + Int64(length) - 1
        var request = try makeRequest(path: "v1/files/\(file.id)", token: token)
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        do {
            let (data, _) = try await send(request, limit: length, accepting: [206]) { response in
                guard response.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(end)/\(file.size)",
                      response.value(forHTTPHeaderField: "Content-Length").map({ $0 == String(length) }) ?? true else {
                    throw DriveCompanionError.invalidRange
                }
            }
            guard data.count == length else { throw DriveCompanionError.invalidRange }
            return data
        } catch DriveCompanionError.http(let code) where code == 401 || code == 403 {
            throw DriveCompanionError.reconnectRequired
        } catch DriveCompanionError.http(let code) where code == 200 || code == 416 {
            throw DriveCompanionError.invalidRange
        }
    }

    private static func endpoint(from address: String?) -> URL? {
        guard let address, var parts = URLComponents(string: address),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/" else { return nil }
        parts.scheme = "https"
        parts.host = host.lowercased()
        parts.percentEncodedPath = ""
        return parts.url
    }

    private func validate(_ pairing: DriveCompanionPairing) throws {
        guard Self.identifier(pairing.id), Self.identifier(pairing.secret, length: 32...128),
              (4...12).contains(pairing.code.utf8.count), pairing.code.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || $0 == 45
              }), (1...900).contains(pairing.expiresIn),
              var browser = URLComponents(url: pairing.verificationUrl, resolvingAgainstBaseURL: false),
              browser.percentEncodedPath == "/pair", browser.query == nil, browser.fragment == nil else {
            throw DriveCompanionError.invalidResponse
        }
        browser.percentEncodedPath = ""
        guard let origin = Self.endpoint(from: browser.string), origin.host == base.host,
              (origin.port ?? 443) == (base.port ?? 443) else { throw DriveCompanionError.invalidResponse }
    }

    private static func identifier(_ value: String, length: ClosedRange<Int> = 1...256) -> Bool {
        length.contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func validate(_ files: [DriveCompanionFile]) throws {
        guard (1...512).contains(files.count) else { throw DriveCompanionError.invalidResponse }
        var seen: Set<String> = []
        for file in files {
            guard identifier(file.id), seen.insert(file.id).inserted, file.size > 0,
                  file.parentId.map({ identifier($0) }) ?? true,
                  (1...255).contains(file.name.utf8.count), file.name != ".", file.name != "..",
                  !file.name.contains("/"), !file.name.contains("\\"),
                  file.name.rangeOfCharacter(from: .controlCharacters) == nil,
                  (1...255).contains(file.mimeType.utf8.count), file.mimeType.contains("/"),
                  file.mimeType.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw DriveCompanionError.invalidResponse
            }
        }
    }

    private func makeRequest(path: String, method: String = "GET", token: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token {
            guard Self.identifier(token, length: 32...128) else { throw DriveCompanionError.reconnectRequired }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        return request
    }

    private func json<T: Decodable>(_ request: URLRequest, status: Int = 200) async throws -> T {
        let (data, _) = try await send(request, limit: Self.jsonLimit, accepting: [status])
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DriveCompanionError.invalidResponse }
    }

    private func send(_ request: URLRequest, limit: Int, accepting codes: Set<Int>, ignoreBody: Bool = false,
                      validateResponse: (HTTPURLResponse) throws -> Void = { _ in }) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.url == request.url else { throw DriveCompanionError.invalidResponse }
            guard codes.contains(http.statusCode) else { throw DriveCompanionError.http(http.statusCode) }
            if ignoreBody { return (Data(), http) }
            guard http.expectedContentLength <= Int64(limit),
                  http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
                throw DriveCompanionError.invalidResponse
            }
            try validateResponse(http)
            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < limit else { throw DriveCompanionError.invalidResponse }
                data.append(byte)
            }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as DriveCompanionError {
            throw error
        } catch {
            throw DriveCompanionError.unavailable
        }
    }
}
