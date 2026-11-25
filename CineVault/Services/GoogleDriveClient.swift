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
        var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
    }

    private struct Page: Decodable {
        let files: [Entry]
        let nextPageToken: String?
    }

    private static let base = URL(string: "https://www.googleapis.com/drive/v3/files")!
    private static let maximumBytes = 8 * 1024 * 1024
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: GoogleDriveRedirectDelegate(), delegateQueue: nil)
    }()

    func listChildren(parent: String, accessToken: String, onPage: ([Entry]) async throws -> Void) async throws {
        guard Self.isFileID(parent) else { throw GoogleDriveError.invalidRequest }
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            try Task.checkCancellation()
            var query = [
                URLQueryItem(name: "q", value: "'\(parent)' in parents and trashed = false"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size)"),
                URLQueryItem(name: "pageSize", value: "100"),
            ]
            if let cursor { query.append(URLQueryItem(name: "pageToken", value: cursor)) }
            let request = try makeRequest(url: Self.base, accessToken: accessToken, query: query)
            let (data, _) = try await Self.send(request, limit: Self.maximumBytes, expectedStatus: 200)
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

    func read(fileID: String, offset: Int64, length: Int, accessToken: String) async throws -> Data {
        guard Self.isFileID(fileID), offset >= 0, (1...Self.maximumBytes).contains(length),
              offset <= Int64.max - Int64(length) else { throw GoogleDriveError.invalidRequest }
        let end = offset + Int64(length) - 1
        var request = try makeRequest(url: Self.base.appendingPathComponent(fileID), accessToken: accessToken,
                                      query: [URLQueryItem(name: "alt", value: "media")])
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await Self.send(request, limit: length, expectedStatus: 206)
        guard let range = response.value(forHTTPHeaderField: "Content-Range"),
              range.hasPrefix("bytes \(offset)-\(end)/"), let total = Int64(range.split(separator: "/").last ?? ""),
              total > end, data.count == length,
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

    private static func send(_ request: URLRequest, limit: Int, expectedStatus: Int) async throws -> (Data, HTTPURLResponse) {
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
