import Foundation
import Network

/// AVPlayer uses ordinary HLS URLs on a private loopback port. The Jellyfin token
/// stays in HTTPS headers, including for child playlists and segments.
final class JellyfinHLSRelay: @unchecked Sendable {
    private static let loopback = "127.0.0.1"
    private static let headerLimit = 8 * 1024
    private static let connectionLimit = 8
    private static let resourceLimit = 65_536

    private struct ClientRequest {
        let target: String
        let headOnly: Bool
        let range: String?

        init(_ bytes: Data) throws {
            guard let text = String(data: bytes, encoding: .utf8) else { throw JellyfinClientError.invalidResponse }
            let lines = text.components(separatedBy: "\r\n")
            let fields = lines.first?.split(separator: " ") ?? []
            guard fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD",
                  fields[2] == "HTTP/1.1" || fields[2] == "HTTP/1.0",
                  fields[1].utf8.count <= 80 else { throw JellyfinClientError.invalidResponse }
            target = String(fields[1])
            headOnly = fields[0] == "HEAD"
            var range: String?
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                if name == "range" {
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    guard range == nil, value.range(of: #"^bytes=[0-9]{1,19}-[0-9]{0,19}$"#,
                                                    options: .regularExpression) != nil else {
                        throw JellyfinClientError.invalidResponse
                    }
                    range = value
                } else if name == "transfer-encoding" || (name == "content-length" && parts[1].trimmingCharacters(in: .whitespaces) != "0") {
                    throw JellyfinClientError.invalidResponse
                }
            }
            self.range = range
        }
    }

    // The listener, connections, and resource lookup table are confined to this queue.
    private let queue = DispatchQueue(label: "cinevault.jellyfin.hls")
    private let listener: NWListener
    private let connection: JellyfinSourceConnection
    private let playback: JellyfinPlayback
    private let allowsRead: @Sendable () -> Bool
    private let prefix = "/" + UUID().uuidString + "/"
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var resources: [URL] = []
    private var indices: [URL: Int] = [:]
    private var stopped = false

    init(connection: JellyfinSourceConnection, playback: JellyfinPlayback, allowsRead: @escaping @Sendable () -> Bool) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(Self.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.connection = connection
        self.playback = playback
        self.allowsRead = allowsRead
        resources.append(playback.url)
        indices[playback.url] = 0
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                queue.async {
                    guard !self.stopped else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.listener.newConnectionHandler = { [weak self] client in
                        if let self { self.accept(client) } else { client.cancel() }
                    }
                    self.listener.stateUpdateHandler = { [weak self] state in
                        guard let self else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        switch state {
                        case .ready:
                            self.listener.stateUpdateHandler = nil
                            guard let port = self.listener.port,
                                  let url = URL(string: "http://\(Self.loopback):\(port.rawValue)\(self.prefix)0.m3u8") else {
                                continuation.resume(throwing: JellyfinClientError.invalidResponse)
                                return
                            }
                            continuation.resume(returning: url)
                        case .failed(let error):
                            self.listener.stateUpdateHandler = nil
                            continuation.resume(throwing: error)
                        case .cancelled:
                            self.listener.stateUpdateHandler = nil
                            continuation.resume(throwing: CancellationError())
                        default:
                            break
                        }
                    }
                    self.listener.start(queue: self.queue)
                }
            }
        } onCancel: { self.stop() }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.listener.cancel()
            for task in self.requests.values { task.cancel() }
            for connection in self.clients.values { connection.cancel() }
            self.requests.removeAll()
            self.clients.removeAll()
            self.resources.removeAll()
            self.indices.removeAll()
        }
    }

    private func accept(_ client: NWConnection) {
        guard !stopped, clients.count < Self.connectionLimit else { client.cancel(); return }
        let id = ObjectIdentifier(client)
        clients[id] = client
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(id)
            default: break
            }
        }
        client.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self, weak client] in
            guard let self, let client, self.clients[id] === client, self.requests[id] == nil else { return }
            self.close(id)
        }
        receive(client, prior: Data())
    }

    private func receive(_ client: NWConnection, prior: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.headerLimit - prior.count) { [weak self, weak client] chunk, _, complete, error in
            guard let self, let client, self.clients[ObjectIdentifier(client)] === client else { return }
            let id = ObjectIdentifier(client)
            guard error == nil, let chunk, !chunk.isEmpty else { self.close(id); return }
            let data = prior + chunk
            if let end = data.range(of: Data("\r\n\r\n".utf8)) {
                guard end.upperBound == data.endIndex, let request = try? ClientRequest(data[..<end.lowerBound]) else {
                    self.reply(id, status: "400 Bad Request")
                    return
                }
                self.fetch(request, clientID: id)
            } else if complete || data.count >= Self.headerLimit {
                self.close(id)
            } else {
                self.receive(client, prior: data)
            }
        }
    }

    private func fetch(_ request: ClientRequest, clientID id: ObjectIdentifier) {
        guard allowsRead(), request.target.hasPrefix(prefix),
              let dot = request.target.lastIndex(of: "."),
              let index = Int(request.target[prefix.endIndex..<dot]),
              resources.indices.contains(index),
              request.target == localPath(index, url: resources[index]) else {
            reply(id, status: "404 Not Found")
            return
        }
        let resource = resources[index]
        let connection = self.connection
        let playlist = resource.pathExtension.lowercased() == "m3u8"
        requests[id] = Task { [weak self] in
            do {
                let response = try await connection.client.readHLS(resource, account: connection.account,
                                                                   range: playlist ? nil : request.range)
                try Task.checkCancellation()
                self?.queue.async { [weak self] in self?.deliver(response, playlist: playlist, resource: resource, request: request, id: id) }
            } catch {
                self?.queue.async { [weak self] in self?.reply(id, status: "502 Bad Gateway") }
            }
        }
    }

    private func deliver(_ response: JellyfinHLSResponse, playlist: Bool, resource: URL, request: ClientRequest, id: ObjectIdentifier) {
        guard clients[id] != nil, allowsRead() else { close(id); return }
        do {
            let body: Data
            if playlist {
                body = try JellyfinHLSPlaylist.rewrite(response.data) { reference in
                    let url = try connection.client.hlsResource(reference, relativeTo: resource, itemID: playback.itemID)
                    if let index = indices[url] { return localPath(index, url: url) }
                    guard resources.count < Self.resourceLimit else { throw JellyfinClientError.invalidResponse }
                    let index = resources.count
                    resources.append(url)
                    indices[url] = index
                    return localPath(index, url: url)
                }
            } else { body = response.data }
            reply(id, status: response.contentRange == nil ? "200 OK" : "206 Partial Content", body: body,
                  type: contentType(resource), range: response.contentRange, headOnly: request.headOnly)
        } catch { reply(id, status: "502 Bad Gateway") }
    }

    private func localPath(_ index: Int, url: URL) -> String {
        prefix + String(index) + "." + url.pathExtension.lowercased()
    }

    private func contentType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "m4s": return "video/iso.segment"
        case "mp4": return "video/mp4"
        case "aac": return "audio/aac"
        case "vtt": return "text/vtt"
        default: return "application/octet-stream"
        }
    }

    private func reply(_ id: ObjectIdentifier, status: String, body: Data = Data(), type: String = "text/plain",
                       range: String? = nil, headOnly: Bool = false) {
        guard let client = clients[id] else { return }
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if let range { header += "Content-Range: \(range)\r\nAccept-Ranges: bytes\r\n" }
        var response = Data((header + "\r\n").utf8)
        if !headOnly { response.append(body) }
        client.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close(id)
        })
    }

    private func close(_ id: ObjectIdentifier) {
        requests.removeValue(forKey: id)?.cancel()
        clients.removeValue(forKey: id)?.cancel()
    }
}

enum JellyfinHLSPlaylist {
    private static let uri = try! NSRegularExpression(pattern: #"(?:[:,])(?:[A-Z0-9-]*-)?URI="([^"]+)""#)

    static func rewrite(_ data: Data, replace: (String) throws -> String) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { throw JellyfinClientError.invalidResponse }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "#EXTM3U", lines.count <= 65_536 else { throw JellyfinClientError.invalidResponse }
        let rewritten = try lines.map { line -> String in
            guard !line.isEmpty else { return line }
            if !line.hasPrefix("#") { return try replace(line) }
            // Text on comment lines is not a URI. HLS attributes name external resources with URI=.
            guard line.hasPrefix("#EXT-X-") else { return line }
            guard !line.hasPrefix("#EXT-X-DEFINE:") else { throw JellyfinClientError.invalidResponse }
            let string = line as NSString
            let matches = uri.matches(in: line, range: NSRange(location: 0, length: string.length))
            let result = NSMutableString(string: line)
            for match in matches.reversed() {
                let value = match.range(at: 1)
                result.replaceCharacters(in: value, with: try replace(string.substring(with: value)))
            }
            return result as String
        }
        return Data(rewritten.joined(separator: "\n").utf8)
    }
}
