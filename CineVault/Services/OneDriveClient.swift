import Foundation

enum OneDriveError: LocalizedError {
    case invalidClient, invalidResponse, expired, denied, rejected(Int)

    var errorDescription: String? {
        switch self {
        case .invalidClient: return "Configure a Microsoft public client application ID."
        case .invalidResponse: return "Microsoft returned an invalid OneDrive response."
        case .expired: return "The Microsoft sign-in code expired."
        case .denied: return "Microsoft sign-in was declined."
        case .rejected(let status): return "Microsoft rejected the request (HTTP \(status))."
        }
    }
}

private final class OneDriveRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct OneDriveClient: Sendable {
    struct Challenge: Decodable, Sendable {
        let user_code: String
        let verification_uri: URL
        fileprivate let device_code: String
        fileprivate let expires_in: Int
        fileprivate let interval: Int?
        fileprivate let received = ContinuousClock.now

        enum CodingKeys: String, CodingKey {
            case user_code, verification_uri, device_code, expires_in, interval
        }
    }

    struct Credentials: Decodable, Sendable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    struct Entry: Decodable, Sendable {
        struct Folder: Decodable, Sendable { let childCount: Int? }
        struct File: Decodable, Sendable { let mimeType: String? }
        struct RemoteItem: Decodable, Sendable { let id: String? }
        let id: String
        let name: String
        let size: Int64?
        let folder: Folder?
        let file: File?
        let remoteItem: RemoteItem?

        var localItem: CloudFileTransport.Item? {
            guard remoteItem == nil, OneDriveClient.isItemID(id) else { return nil }
            if folder != nil { return .init(id: id, name: name, isDirectory: true, size: 0) }
            guard file != nil, let size, size >= 0 else { return nil }
            return .init(id: id, name: name, isDirectory: false, size: size)
        }
    }

    struct DriveIdentity: Decodable, Sendable { let id: String }

    private struct GraphPage: Decodable {
        let value: [Entry]
        let next: URL?
        enum CodingKeys: String, CodingKey { case value; case next = "@odata.nextLink" }
    }

    private struct DownloadItem: Decodable {
        let id: String
        let downloadURL: URL?
        enum CodingKeys: String, CodingKey {
            case id
            case downloadURL = "@microsoft.graph.downloadUrl"
        }
    }

    private struct OAuthError: Decodable { let error: String }
    private static let scope = "https://graph.microsoft.com/Files.Read offline_access"
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config, delegate: OneDriveRedirectDelegate(), delegateQueue: nil)
    }()
    private let clientID: String
    private let session: URLSession

    init(clientID: String, session: URLSession? = nil) throws {
        guard let id = UUID(uuidString: clientID) else { throw OneDriveError.invalidClient }
        self.clientID = id.uuidString.lowercased()
        self.session = session ?? Self.defaultSession
    }

    func beginSignIn() async throws -> Challenge {
        let (data, status) = try await oauth("devicecode", fields: ["scope": Self.scope])
        guard status == 200 else { throw OneDriveError.rejected(status) }
        let result = try JSONDecoder().decode(Challenge.self, from: data)
        guard result.verification_uri.scheme == "https", result.verification_uri.host == "microsoft.com" ||
                result.verification_uri.host == "www.microsoft.com" || result.verification_uri.host == "login.microsoftonline.com",
              result.verification_uri.user == nil, result.verification_uri.password == nil,
              (1...3600).contains(result.expires_in), !result.device_code.isEmpty, !result.user_code.isEmpty else {
            throw OneDriveError.invalidResponse
        }
        return result
    }

    func completeSignIn(_ challenge: Challenge) async throws -> Credentials {
        let clock = ContinuousClock()
        let deadline = challenge.received.advanced(by: .seconds(challenge.expires_in))
        var interval = min(max(challenge.interval ?? 5, 1), 60)
        while clock.now < deadline {
            try await clock.sleep(until: min(clock.now.advanced(by: .seconds(interval)), deadline))
            guard clock.now < deadline else { break }
            let (data, status) = try await oauth("token", fields: [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": challenge.device_code,
            ])
            if status == 200 { return try JSONDecoder().decode(Credentials.self, from: data) }
            switch (try? JSONDecoder().decode(OAuthError.self, from: data))?.error {
            case "authorization_pending": continue
            case "slow_down": interval = min(interval + 5, 3600)
            case "authorization_declined": throw OneDriveError.denied
            case "expired_token": throw OneDriveError.expired
            default: throw OneDriveError.rejected(status)
            }
        }
        throw OneDriveError.expired
    }

    func refresh(_ refreshToken: String) async throws -> Credentials {
        let (data, status) = try await oauth("token", fields: [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "scope": Self.scope,
        ])
        guard status == 200 else { throw OneDriveError.rejected(status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    func identifyDrive(accessToken: String) async throws -> String {
        let drive: DriveIdentity = try await graph("https://graph.microsoft.com/v1.0/me/drive", fields: ["id"], token: accessToken)
        guard Self.isItemID(drive.id) else { throw OneDriveError.invalidResponse }
        return drive.id
    }

    func rootFolder(accessToken: String) async throws -> CloudFileTransport.Item {
        let entry: Entry = try await graph("https://graph.microsoft.com/v1.0/me/drive/root",
                                           fields: ["id", "name", "folder", "remoteItem"], token: accessToken)
        guard let item = entry.localItem, item.isDirectory else { throw OneDriveError.invalidResponse }
        return item
    }

    func listChildren(folderID: String? = nil, accessToken: String, driveID: String? = nil,
                      authorize: CloudFileTransport.Permission = {},
                      onPage: ([Entry]) async throws -> Void) async throws {
        var endpoint = URL(string: "https://graph.microsoft.com/v1.0/me/drive")!
        if let folderID {
            guard Self.isItemID(folderID) else { throw OneDriveError.invalidResponse }
            endpoint.appendPathComponent("items")
            endpoint.appendPathComponent(folderID)
        } else {
            endpoint.appendPathComponent("root")
        }
        endpoint.appendPathComponent("children")
        guard var requestURL = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OneDriveError.invalidResponse
        }
        requestURL.queryItems = [URLQueryItem(name: "$select", value: "id,name,size,folder,file,remoteItem")]
        var next = requestURL.url
        var seen: Set<URL> = []
        while let url = next {
            try Task.checkCancellation()
            try authorize()
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.scheme == "https", parts.host == "graph.microsoft.com", parts.port == nil,
                  parts.user == nil, parts.password == nil, parts.fragment == nil,
                  Self.isChildPage(parts.path, requested: endpoint.path, folderID: folderID, driveID: driveID),
                  seen.count < 10_000, seen.insert(url).inserted,
                  Self.isToken(accessToken) else {
                throw OneDriveError.invalidResponse
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, status) = try await send(request)
            try authorize()
            guard status == 200 else { throw OneDriveError.rejected(status) }
            let page = try JSONDecoder().decode(GraphPage.self, from: data)
            try await onPage(page.value)
            next = page.next
        }
    }

    /// Resolve a fresh signed link so subsequent seeks do not depend on an expired link.
    func read(fileID: String, offset: Int64, length: Int, accessToken: String, expectedSize: Int64? = nil,
              authorize: CloudFileTransport.Permission = {}) async throws -> Data {
        try authorize()
        guard Self.isItemID(fileID), offset >= 0, (1...8 * 1024 * 1024).contains(length),
              offset <= Int64.max - Int64(length),
              expectedSize.map({ offset + Int64(length) <= $0 }) ?? true,
              Self.isToken(accessToken) else { throw OneDriveError.invalidResponse }
        let endpoint = URL(string: "https://graph.microsoft.com/v1.0/me/drive/items")!.appendingPathComponent(fileID)
        guard var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw OneDriveError.invalidResponse }
        url.queryItems = [URLQueryItem(name: "$select", value: "id,@microsoft.graph.downloadUrl")]
        guard let metadataURL = url.url else { throw OneDriveError.invalidResponse }

        var metadata = URLRequest(url: metadataURL)
        metadata.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await send(metadata)
        try authorize()
        guard status == 200 else { throw OneDriveError.rejected(status) }
        let item = try JSONDecoder().decode(DownloadItem.self, from: data)
        guard item.id == fileID, let link = item.downloadURL,
              let parts = URLComponents(url: link, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443 else { throw OneDriveError.invalidResponse }

        let end = offset + Int64(length) - 1
        var request = URLRequest(url: link)
        // The link is already signed; the Graph bearer credential stays on graph.microsoft.com.
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw OneDriveError.invalidResponse }
        if http.statusCode == 206 {
            guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                  Self.matchesRange(range, offset: offset, end: end, size: expectedSize) else {
                throw OneDriveError.invalidResponse
            }
        } else if http.statusCode != 200 || offset != 0 || expectedSize != Int64(length) {
            throw OneDriveError.rejected(http.statusCode)
        }
        guard response.expectedContentLength < 0 || response.expectedContentLength == Int64(length),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            throw OneDriveError.invalidResponse
        }
        var result = Data()
        for try await byte in bytes {
            guard result.count < length else { throw OneDriveError.invalidResponse }
            result.append(byte)
        }
        try authorize()
        guard result.count == length else { throw OneDriveError.invalidResponse }
        return result
    }

    static func matchesRange(_ header: String, offset: Int64, end: Int64, size: Int64? = nil) -> Bool {
        let prefix = "bytes \(offset)-\(end)/"
        guard header.hasPrefix(prefix), let total = Int64(header.dropFirst(prefix.count)) else { return false }
        return total > end && (size == nil || size == total) && header == prefix + String(total)
    }

    private static func isChildPage(_ path: String, requested: String, folderID: String?, driveID: String?) -> Bool {
        if path == requested { return true }
        // Microsoft Graph can canonicalize an alias under /me/drive to a drive ID in nextLink.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 7 && parts[0].isEmpty && parts[1] == "v1.0" && parts[2] == "drives" &&
            isItemID(String(parts[3])) && parts[4] == "items" && isItemID(String(parts[5])) &&
            (driveID == nil || String(parts[3]) == driveID) &&
            (folderID == nil || String(parts[5]) == folderID) && parts[6] == "children"
    }

    static func isItemID(_ value: String) -> Bool {
        (1...256).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                $0 == 33 || $0 == 45 || $0 == 95
        }
    }

    static func isToken(_ value: String) -> Bool {
        (1...32_768).contains(value.utf8.count) && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    private func graph<T: Decodable>(_ endpoint: String, fields: [String], token: String) async throws -> T {
        guard Self.isToken(token), var components = URLComponents(string: endpoint) else { throw OneDriveError.invalidResponse }
        components.queryItems = [URLQueryItem(name: "$select", value: fields.joined(separator: ","))]
        guard let url = components.url else { throw OneDriveError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await send(request)
        guard status == 200 else { throw OneDriveError.rejected(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func oauth(_ path: String, fields: [String: String]) async throws -> (Data, Int) {
        let base = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0")!
        var request = URLRequest(url: base.appendingPathComponent(path))
        var form = URLComponents()
        form.queryItems = (fields.merging(["client_id": clientID]) { existing, _ in existing }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let body = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") else {
            throw OneDriveError.invalidResponse
        }
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let limit = 8 * 1024 * 1024
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= Int64(limit) else {
            throw OneDriveError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw OneDriveError.invalidResponse }
            data.append(byte)
        }
        return (data, http.statusCode)
    }
}
