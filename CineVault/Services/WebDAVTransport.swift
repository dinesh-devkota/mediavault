import Foundation

enum WebDAVError: LocalizedError {
    case invalidAddress, invalidPath, invalidListing, invalidRange, shortRead, status(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter the full HTTPS WebDAV address without credentials, a query, or a fragment."
        case .invalidPath: return "Choose a file or folder inside this WebDAV source."
        case .invalidListing: return "The server did not return a valid WebDAV folder listing."
        case .invalidRange: return "The server did not return the requested WebDAV byte range."
        case .shortRead: return "The WebDAV file ended unexpectedly. Rescan the source and retry."
        case .status(401): return "The WebDAV server rejected your sign-in."
        case .status(403): return "This account does not have read access to the WebDAV folder or file."
        case .status(300..<400): return "Enter the final WebDAV address. Redirects are blocked to protect your sign-in."
        case .status(let code): return "The WebDAV server returned HTTP \(code)."
        }
    }
}

struct WebDAVAddress: Sendable {
    let endpoint: URL
    private let root: [String]

    init(_ address: String) throws {
        guard var url = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true,
              let root = Self.components(url.percentEncodedPath) else { throw WebDAVError.invalidAddress }
        if !url.percentEncodedPath.hasSuffix("/") { url.percentEncodedPath += "/" }
        guard let endpoint = url.url else { throw WebDAVError.invalidAddress }
        self.endpoint = endpoint
        self.root = root
    }

    func url(for path: String, directory: Bool = false) throws -> URL {
        let parts = path.isEmpty ? [] : path.components(separatedBy: "/")
        guard parts.allSatisfy(Self.isSafeComponent) else { throw WebDAVError.invalidPath }
        var url = endpoint
        for part in parts { url = url.appendingPathComponent(part, isDirectory: false) }
        if directory && !parts.isEmpty { url = url.appendingPathComponent("", isDirectory: true) }
        return url
    }

    func relativePath(href: String, requested: URL) -> String? {
        guard let resolved = URL(string: href, relativeTo: requested)?.absoluteURL,
              let target = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              target.scheme?.lowercased() == "https",
              target.host?.lowercased() == endpoint.host?.lowercased(),
              (target.port ?? 443) == (endpoint.port ?? 443),
              target.user == nil, target.password == nil, target.query == nil, target.fragment == nil,
              let parts = Self.components(target.percentEncodedPath),
              parts.starts(with: root, by: Self.sameComponent) else { return nil }
        return parts.dropFirst(root.count).joined(separator: "/")
    }

    static func contains(_ path: String, within root: String, allowRoot: Bool = false) -> Bool {
        let rootParts = root.isEmpty ? [] : root.components(separatedBy: "/")
        let parts = path.isEmpty ? [] : path.components(separatedBy: "/")
        return rootParts.allSatisfy(isSafeComponent) && parts.allSatisfy(isSafeComponent)
            && (allowRoot ? parts.count >= rootParts.count : parts.count > rootParts.count)
            && parts.starts(with: rootParts, by: sameComponent)
    }

    static func sameComponent(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func components(_ encodedPath: String) -> [String]? {
        if encodedPath.isEmpty || encodedPath == "/" { return [] }
        guard encodedPath.hasPrefix("/") else { return nil }
        var components = encodedPath.dropFirst().components(separatedBy: "/")
        if components.last == "" { components.removeLast() }
        let decoded = components.compactMap { $0.removingPercentEncoding }
        guard decoded.count == components.count, decoded.allSatisfy(isSafeComponent) else { return nil }
        return decoded
    }

    private static func isSafeComponent(_ part: String) -> Bool {
        !part.isEmpty && part != "." && part != ".."
            && !part.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0 == "/" || $0 == "\\" })
            && part.range(of: "%(?:2e|2f|5c|00)", options: [.regularExpression, .caseInsensitive]) == nil
    }
}

struct WebDAVEntry: Equatable, Sendable {
    let path: String
    let isDirectory: Bool
    let size: Int64
}

private final class WebDAVRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct WebDAVTransport: Sendable {
    private static let maximumListingBytes = 8 * 1024 * 1024
    private static let properties = """
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>
        """
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: WebDAVRedirectDelegate(), delegateQueue: nil)
    }()

    let address: WebDAVAddress
    let username: String
    let password: String

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !username.isEmpty {
            let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func list(_ directory: String) async throws -> [WebDAVEntry] {
        let url = try address.url(for: directory, directory: true)
        var request = request(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.properties.utf8)
        let (bytes, response) = try await Self.session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidListing }
        guard http.statusCode == 207 else { throw WebDAVError.status(http.statusCode) }
        guard response.expectedContentLength <= Int64(Self.maximumListingBytes) else { throw WebDAVError.invalidListing }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumListingBytes else { throw WebDAVError.invalidListing }
            data.append(byte)
        }
        return try Self.parseListing(data, address: address, requested: url, directory: directory)
    }

    func read(_ path: String, offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length >= 0, Int64(length) <= Int64.max - offset else { throw WebDAVError.invalidRange }
        guard length > 0 else { return Data() }
        return try await range(path, offset: offset, length: length).data
    }

    func fileSize(_ path: String) async throws -> Int64 {
        try await range(path, offset: 0, length: 1, allowEmpty: true).total
    }

    private func range(_ path: String, offset: Int64, length: Int, allowEmpty: Bool = false) async throws -> (data: Data, total: Int64) {
        var request = request(url: try address.url(for: path))
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await Self.session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidRange }
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        if allowEmpty, http.statusCode == 416, contentRange == "bytes */0" { return (Data(), 0) }
        guard (200..<300).contains(http.statusCode) else { throw WebDAVError.status(http.statusCode) }
        guard http.statusCode == 206,
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
              let contentRange, let bounds = Self.parseRange(contentRange), bounds.start == offset,
              bounds.end == offset + Int64(length) - 1,
              response.expectedContentLength < 0 || response.expectedContentLength == Int64(length) else {
            throw WebDAVError.invalidRange
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < length else { throw WebDAVError.invalidRange }
            data.append(byte)
        }
        guard data.count == length else { throw WebDAVError.shortRead }
        return (data, bounds.total)
    }

    static func parseRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let fields = value.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard fields.count == 3, let start = Int64(fields[0]), let end = Int64(fields[1]), let total = Int64(fields[2]),
              start >= 0, end >= start, end < total, value == "bytes \(start)-\(end)/\(total)" else { return nil }
        return (start, end, total)
    }

    static func parseListing(_ data: Data, address: WebDAVAddress, requested: URL, directory: String) throws -> [WebDAVEntry] {
        guard data.count <= maximumListingBytes, !data.contains(0), let text = String(data: data, encoding: .utf8),
              text.range(of: "<!\\s*(?:DOCTYPE|ENTITY)", options: [.regularExpression, .caseInsensitive]) == nil else {
            throw WebDAVError.invalidListing
        }
        let parser = XMLParser(data: data)
        let listing = WebDAVListing(address: address, requested: requested, directory: directory)
        parser.delegate = listing
        parser.shouldProcessNamespaces = true
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), listing.confirmedDirectory else { throw WebDAVError.invalidListing }
        return listing.entries.values.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

private final class WebDAVListing: NSObject, XMLParserDelegate {
    private static let response = "/multistatus/response"
    private static let propstat = response + "/propstat"
    private static let prop = propstat + "/prop"
    private let address: WebDAVAddress
    private let requested: URL
    private let directory: String
    private var stack: [String] = []
    private var text = ""
    private var href: String?
    private var responseStatus: String?
    private var propertyStatus = ""
    private var propertyDirectory = false
    private var propertySize: Int64 = 0
    private var successful = false
    private var isDirectory = false
    private var size: Int64 = 0
    private var responses = 0
    private(set) var confirmedDirectory = false
    private(set) var entries: [Data: WebDAVEntry] = [:]

    init(address: WebDAVAddress, requested: URL, directory: String) {
        self.address = address
        self.requested = requested
        self.directory = directory
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        stack.append(namespaceURI == "DAV:" ? elementName : "?")
        text = ""
        guard stack.count <= 32 else { parser.abortParsing(); return }
        switch "/" + stack.joined(separator: "/") {
        case Self.response:
            responses += 1
            if responses > 100_000 { parser.abortParsing() }
            href = nil; responseStatus = nil; successful = false; isDirectory = false; size = 0
        case Self.propstat:
            propertyStatus = ""; propertyDirectory = false; propertySize = 0
        case Self.prop + "/resourcetype/collection":
            propertyDirectory = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch "/" + stack.joined(separator: "/") {
        case Self.response + "/href":
            if href != nil { parser.abortParsing() }
            href = value
        case Self.response + "/status": responseStatus = value
        case Self.propstat + "/status": propertyStatus = value
        case Self.prop + "/getcontentlength": propertySize = max(Int64(value) ?? 0, 0)
        case Self.propstat:
            if Self.isSuccess(propertyStatus) {
                successful = true
                isDirectory = isDirectory || propertyDirectory
                size = max(size, propertySize)
            }
        case Self.response: acceptResponse(parser)
        default: break
        }
        stack.removeLast()
        text = ""
    }

    private static func isSuccess(_ status: String) -> Bool {
        status.range(of: "^HTTP/\\S+ 200(?: .*)?$", options: .regularExpression) != nil
    }

    private func acceptResponse(_ parser: XMLParser) {
        guard let href, !href.isEmpty, let path = address.relativePath(href: href, requested: requested) else { return }
        let succeeded = successful && (responseStatus.map(Self.isSuccess) ?? true)
        if WebDAVAddress.sameComponent(path, directory) {
            guard succeeded, isDirectory, !confirmedDirectory else { parser.abortParsing(); return }
            confirmedDirectory = true
        } else if succeeded && WebDAVAddress.sameComponent(path.components(separatedBy: "/").dropLast().joined(separator: "/"), directory) {
            let entry = WebDAVEntry(path: path, isDirectory: isDirectory, size: size)
            let key = Data(path.utf8)
            if let existing = entries[key], existing != entry { parser.abortParsing(); return }
            entries[key] = entry
        }
    }
}
