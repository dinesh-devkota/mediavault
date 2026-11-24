import Foundation
import CoreFoundation

enum SubDLMediaType: String, Sendable { case movie, tv }

struct SubDLSearchQuery: Sendable, Equatable {
    let tmdbID: Int
    let type: SubDLMediaType
    let season: Int?
    let episode: Int?
    let language: String

    init(tmdbID: Int, type: SubDLMediaType, season: Int? = nil, episode: Int? = nil, language: String = "en") {
        self.tmdbID = tmdbID; self.type = type; self.season = season; self.episode = episode; self.language = language
    }
}

struct SubDLSubtitle: Identifiable, Sendable, Equatable {
    let id: String
    let language: String
    let releaseName: String
    let format: String
    let hearingImpaired: Bool
    let downloadURL: URL
    let fps: Double?
    var releaseNames: [String] = []
}

enum SubDLError: Error, LocalizedError, Equatable {
    case missingKey, invalidKey, quota, connection, noResults, invalidResponse, tooLarge, invalidQuery, unsafeDownload

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Connect SubDL in Settings to find subtitles."
        case .invalidKey: return "SubDL could not verify this API key. Check it in Settings."
        case .quota: return "SubDL's request limit has been reached. Try again after the limit resets."
        case .connection: return "Could not reach SubDL. Check your internet connection and device date and time, then try again."
        case .noResults: return "No matching SRT or VTT subtitles were found for this title and language."
        case .invalidResponse: return "SubDL returned an unsupported response. Try again later or use a subtitle from your NAS."
        case .tooLarge: return "This subtitle exceeds the 2 MB limit. Choose another subtitle."
        case .invalidQuery: return "Match this title and episode in the library before finding subtitles."
        case .unsafeDownload: return "This subtitle download is not supported. Choose another subtitle."
        }
    }
}

struct SubDLHTTPResponse: Sendable {
    let statusCode: Int
    let url: URL
    let data: Data
}

/// Search uses the documented v2 API. Only individually identified, unpacked files are downloaded.
/// Credentials are supplied per request and never retained in subtitle models or cache identifiers.
struct SubDLClient: Sendable {
    typealias Transport = @Sendable (URLRequest, Int) async throws -> SubDLHTTPResponse
    static let maximumBytes = 2 * 1_024 * 1_024
    private let transport: Transport

    init() { self.transport = { request, maximum in try await Self.load(request, maximumBytes: maximum) } }
    init(transport: @escaping Transport) { self.transport = transport }

    func validateKey(_ apiKey: String) async throws {
        let request = try Self.apiRequest(path: "/api/v2/me", apiKey: apiKey)
        let body = try await json(request)
        guard let plan = body["plan"] as? [String: Any],
              let name = plan["name"] as? String, !name.isEmpty,
              let usage = body["usage"] as? [String: Any], usage["search"] is [String: Any] else {
            throw SubDLError.invalidResponse
        }
    }

    func search(_ query: SubDLSearchQuery, apiKey: String) async throws -> [SubDLSubtitle] {
        let language = try Self.normalizedLanguage(query.language)
        guard query.tmdbID > 0 else { throw SubDLError.invalidQuery }
        var parameters = ["tmdb_id": String(query.tmdbID), "type": query.type.rawValue,
                          "languages": language, "unpack": "1", "releases": "1",
                          "client": "custom_integration", "subs_per_page": "30"]
        if query.type == .tv {
            guard let season = query.season, let episode = query.episode,
                  (0...999).contains(season), (0...999).contains(episode) else { throw SubDLError.invalidQuery }
            parameters["season"] = String(season); parameters["episode"] = String(episode)
            parameters["full_season"] = "0"
        } else if query.season != nil || query.episode != nil { throw SubDLError.invalidQuery }
        let request = try Self.apiRequest(path: "/api/v2/subtitles/search", parameters: parameters, apiKey: apiKey)
        let body = try await json(request)
        guard let identities = body["results"] as? [[String: Any]], let first = identities.first,
              Self.integer(first["tmdb_id"]) == query.tmdbID,
              first["type"] as? String == query.type.rawValue else { throw SubDLError.noResults }
        // The API associates subtitles with the FIRST result, not any later identity in the array.
        guard let rows = body["subtitles"] as? [[String: Any]] else { throw SubDLError.noResults }
        var found: [SubDLSubtitle] = []
        var seen = Set<URL>()
        for row in rows.prefix(30) {
            guard let files = row["unpack_files"] as? [[String: Any]] else { continue }
            for file in files {
                guard let rawFormat = file["format"] as? String,
                      ["srt", "vtt"].contains(rawFormat.lowercased()),
                      let rawLanguage = file["language"] as? String,
                      let fileLanguage = try? Self.normalizedLanguage(rawLanguage), fileLanguage == language,
                      let rawURL = file["url"] as? String, let url = Self.normalizedResultDownloadURL(rawURL),
                      let fileID = file["file_n_id"] as? String, fileID == url.lastPathComponent,
                      Self.integer(file["size"]).map({ $0 > 0 && $0 <= Self.maximumBytes }) ?? true else { continue }
                if query.type == .tv {
                    // An archive-level season or release name is insufficient to identify its individual file.
                    guard Self.integer(file["season"]) == query.season,
                          Self.integer(file["episode"]) == query.episode else { continue }
                } else if (Self.integer(file["season"]) ?? 0) != 0 || (Self.integer(file["episode"]) ?? 0) != 0 {
                    continue
                }
                guard seen.insert(url).inserted else { continue }
                let release = (file["release_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (row["release_name"] as? String) ?? (file["name"] as? String) ?? "Subtitle"
                let rawFPS = file["fps"] ?? row["fps"]
                let fps = Self.double(rawFPS).flatMap { $0.isFinite && $0 > 0 && $0 <= 240 ? $0 : nil }
                let releases = ([release] + (file["releases"] as? [String] ?? []) + (row["releases"] as? [String] ?? []))
                    .filter { !$0.isEmpty }.prefix(100).map { String($0.prefix(512)) }
                found.append(SubDLSubtitle(id: url.absoluteString, language: fileLanguage,
                    releaseName: String(release.prefix(512)), format: rawFormat.lowercased(),
                    hearingImpaired: Self.boolean(file["hi"]) ?? Self.boolean(row["hi"]) ?? false,
                    downloadURL: url, fps: fps, releaseNames: releases))
                if found.count == 30 { return found }
            }
        }
        guard !found.isEmpty else { throw SubDLError.noResults }
        return found
    }

    func download(_ subtitle: SubDLSubtitle, apiKey: String) async throws -> Data {
        guard ["srt", "vtt"].contains(subtitle.format),
              let url = Self.safeDownloadURL(subtitle.downloadURL.absoluteString) else { throw SubDLError.unsafeDownload }
        let key = try Self.validatedKey(apiKey)
        // SubDL's raw download route requires query authentication. Use only the caller's current
        // key, never the credential returned by search; the authenticated URL lives only in this request.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api_key", value: key)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.setValue("text/plain, text/vtt, application/octet-stream", forHTTPHeaderField: "Accept")
        let reply = try await fetch(request)
        // A mislabeled archive is never passed to an extractor or stored as a subtitle.
        guard !reply.data.isEmpty, !reply.data.starts(with: [0x50, 0x4b]),
              !reply.data.starts(with: [0x52, 0x61, 0x72, 0x21]) else { throw SubDLError.invalidResponse }
        return reply.data
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let reply = try await fetch(request)
        guard let body = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any] else {
            throw SubDLError.invalidResponse
        }
        if let error = body["error"] as? [String: Any], let code = error["code"] as? String {
            if ["quota_exceeded", "rate_limit_exceeded", "rate_limited"].contains(code) { throw SubDLError.quota }
            if ["invalid_api_key", "invalid_key", "unauthorized", "missing_api_key"].contains(code) { throw SubDLError.invalidKey }
            throw SubDLError.invalidResponse
        }
        if Self.boolean(body["status"]) == false || (body["error"] != nil && !(body["error"] is NSNull)) {
            throw SubDLError.invalidResponse
        }
        return body
    }

    private func fetch(_ request: URLRequest) async throws -> SubDLHTTPResponse {
        do {
            try Task.checkCancellation()
            let reply = try await transport(request, Self.maximumBytes)
            try Task.checkCancellation()
            guard reply.url == request.url else { throw SubDLError.unsafeDownload }
            guard reply.data.count <= Self.maximumBytes else { throw SubDLError.tooLarge }
            switch reply.statusCode {
            case 200...299: return reply
            case 401, 403:
                throw SubDLError.invalidKey
            case 429: throw SubDLError.quota
            case 300...399: throw SubDLError.unsafeDownload
            default: throw SubDLError.connection
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as SubDLError { throw error }
        catch { throw SubDLError.connection }
    }

    private static func apiRequest(path: String, parameters: [String: String] = [:], apiKey: String) throws -> URLRequest {
        let key = try validatedKey(apiKey)
        var components = URLComponents(string: "https://api.subdl.com" + path)!
        if !parameters.isEmpty {
            components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func validatedKey(_ apiKey: String) throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SubDLError.missingKey }
        guard key.utf8.count <= 4_096, key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw SubDLError.invalidKey
        }
        return key
    }

    private static func normalizedLanguage(_ value: String) throws -> String {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        guard code.range(of: "^[a-z]{2,3}(-[a-z]{2,4})?$", options: .regularExpression) != nil else {
            throw SubDLError.invalidQuery
        }
        return code
    }

    static func normalizedResultDownloadURL(_ value: String) -> URL? {
        let absolute = value.hasPrefix("/subtitle/") ? "https://dl.subdl.com" + value : value
        guard var parts = URLComponents(string: absolute) else { return nil }
        if let query = parts.percentEncodedQuery {
            guard query.hasPrefix("api_key="), !query.contains(";"),
                  let items = parts.queryItems, items.count == 1,
                  items[0].name == "api_key", let value = items[0].value, !value.isEmpty else { return nil }
            parts.percentEncodedQuery = nil
        }
        guard let sanitized = parts.url else { return nil }
        return safeDownloadURL(sanitized.absoluteString)
    }

    static func safeDownloadURL(_ value: String) -> URL? {
        // Only the documented per-file route is accepted. Encodings, dot segments and query strings are unnecessary here.
        let absolute = value.hasPrefix("/subtitle/") ? "https://dl.subdl.com" + value : value
        guard let parts = URLComponents(string: absolute), parts.scheme == "https", parts.host == "dl.subdl.com",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.range(of: "^/subtitle/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return parts.url
    }

    private static func integer(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int32.min), number.doubleValue <= Double(Int32.max) else { return nil }
        return number.intValue
    }
    private static func double(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text) }
        return (value as? NSNumber)?.doubleValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func load(_ request: URLRequest, maximumBytes: Int) async throws -> SubDLHTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: SubDLNoRedirects())
        guard let http = response as? HTTPURLResponse, let url = http.url else { throw SubDLError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            return SubDLHTTPResponse(statusCode: http.statusCode, url: url, data: Data())
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw SubDLError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw SubDLError.tooLarge }
            data.append(byte)
        }
        return SubDLHTTPResponse(statusCode: http.statusCode, url: url, data: data)
    }
}

private final class SubDLNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
