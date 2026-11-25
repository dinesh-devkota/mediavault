import Foundation

enum GoogleDriveError: Error {
    case invalidRequest, invalidResponse, http(Int)
}

private final class GoogleDriveRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Uses an authorized scope supplied by the caller. A per-file grant only returns files shared with the app.
struct GoogleDriveClient: Sendable {
    struct Entry: Decodable, Sendable, Identifiable {
        let id: String
        let name: String
        let mimeType: String
        let size: String?
        let resourceKey: String?
        var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
    }

    private struct Page: Decodable {
        let files: [Entry]
        let nextPageToken: String?
    }

    private static let base = URL(string: "https://www.googleapis.com/drive/v3/files")!
    private static let maximumBytes = 8 * 1024 * 1024
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: GoogleDriveRedirectDelegate(), delegateQueue: nil)
    }()

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.defaultSession
    }

    func listChildren(parent: String, resourceKey: String? = nil, accessToken: String,
                      onPage: ([Entry]) async throws -> Void) async throws {
        guard Self.isFileID(parent) else { throw GoogleDriveError.invalidRequest }
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            try Task.checkCancellation()
            var query = [
                URLQueryItem(name: "q", value: "'\(parent)' in parents and trashed = false"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,resourceKey)"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                URLQueryItem(name: "pageSize", value: "100"),
            ]
            if let cursor { query.append(URLQueryItem(name: "pageToken", value: cursor)) }
            var request = try makeRequest(url: Self.base, accessToken: accessToken, query: query)
            try Self.setResourceKey(resourceKey, for: parent, on: &request)
            let (data, _) = try await send(request, limit: Self.maximumBytes, expectedStatus: 200)
            let page = try JSONDecoder().decode(Page.self, from: data)
            if let next = page.nextPageToken {
                guard !next.isEmpty, seen.count < 10_000, seen.insert(next).inserted else {
                    throw GoogleDriveError.invalidResponse
                }
            }
            try await onPage(page.files)
            cursor = page.nextPageToken
        } while cursor != nil
    }

    func read(fileID: String, offset: Int64, length: Int, resourceKey: String? = nil, accessToken: String) async throws -> Data {
        guard Self.isFileID(fileID), offset >= 0, (1...Self.maximumBytes).contains(length),
              offset <= Int64.max - Int64(length) else { throw GoogleDriveError.invalidRequest }
        let end = offset + Int64(length) - 1
        var request = try makeRequest(url: Self.base.appendingPathComponent(fileID), accessToken: accessToken,
                                      query: [URLQueryItem(name: "alt", value: "media"),
                                              URLQueryItem(name: "supportsAllDrives", value: "true")])
        try Self.setResourceKey(resourceKey, for: fileID, on: &request)
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await send(request, limit: length, expectedStatus: 206)
        guard let range = response.value(forHTTPHeaderField: "Content-Range"),
              Self.matchesRange(range, offset: offset, end: end), data.count == length,
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            throw GoogleDriveError.invalidResponse
        }
        return data
    }

    private func makeRequest(url: URL, accessToken: String, query: [URLQueryItem]) throws -> URLRequest {
        guard !accessToken.isEmpty, accessToken.utf8.allSatisfy({ (33...126).contains($0) }),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GoogleDriveError.invalidRequest
        }
        components.queryItems = query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let target = components.url else { throw GoogleDriveError.invalidRequest }
        var request = URLRequest(url: target)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func matchesRange(_ header: String, offset: Int64, end: Int64) -> Bool {
        let prefix = "bytes \(offset)-\(end)/"
        guard header.hasPrefix(prefix), let total = Int64(header.dropFirst(prefix.count)) else { return false }
        return total > end && header == prefix + String(total)
    }

    private static func setResourceKey(_ key: String?, for fileID: String, on request: inout URLRequest) throws {
        guard let key else { return }
        guard isFileID(key) else { throw GoogleDriveError.invalidRequest }
        request.setValue("\(fileID)/\(key)", forHTTPHeaderField: "X-Goog-Drive-Resource-Keys")
    }

    private func send(_ request: URLRequest, limit: Int, expectedStatus: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw GoogleDriveError.invalidResponse }
        guard http.statusCode == expectedStatus else { throw GoogleDriveError.http(http.statusCode) }
        guard response.expectedContentLength <= Int64(limit) else { throw GoogleDriveError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw GoogleDriveError.invalidResponse }
            data.append(byte)
        }
        return (data, http)
    }

    private static func isFileID(_ value: String) -> Bool {
        (1...256).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
