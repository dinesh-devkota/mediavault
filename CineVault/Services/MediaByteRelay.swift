import Foundation
import Network

/// A single-file, read-only loopback endpoint for decoders that cannot use AVAssetResourceLoader.
/// The decoder receives only an unguessable local URL; NAS credentials never leave the provider.
final class MediaByteRelay: @unchecked Sendable {
    struct Range: Equatable {
        let start: Int64
        let end: Int64 // exclusive
        static func parse(_ value: String?, size: Int64) throws -> Range {
            guard size > 0 else { throw SMBError.invalidFileSize }
            guard let value else { return Range(start: 0, end: size) }
            guard value.hasPrefix("bytes="), !value.contains(",") else { throw SMBError.invalidByteRange }
            let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ $0.isEmpty || $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { throw SMBError.invalidByteRange }
            if parts[0].isEmpty {
                guard let length = Int64(parts[1]), length > 0 else { throw SMBError.invalidByteRange }
                return Range(start: max(0, size - min(size, length)), end: size)
            }
            guard let start = Int64(parts[0]), start >= 0, start < size else { throw SMBError.invalidByteRange }
            if parts[1].isEmpty { return Range(start: start, end: size) }
            guard let last = Int64(parts[1]), last >= start else { throw SMBError.invalidByteRange }
            return Range(start: start, end: min(last, size - 1) + 1)
        }
    }

    private let queue = DispatchQueue(label: "mediavault.media-relay")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let listener: NWListener
    private let reader: SMBResourceLoader.Reader
    private let authorize: @Sendable () async -> Bool
    private let target: String
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopped = false
    private let headerLimit = 8192

    init(fileExtension: String, reader: SMBResourceLoader.Reader, authorize: @escaping @Sendable () async -> Bool) throws {
        self.reader = reader; self.authorize = authorize
        let ext = fileExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        target = "/" + UUID().uuidString + "/media." + (ext.isEmpty ? "bin" : ext)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                queue.async {
                    guard !self.stopped else { continuation.resume(throwing: CancellationError()); return }
                    self.listener.newConnectionHandler = { [weak self] client in
                        if let self { self.accept(client) } else { client.cancel() }
                    }
                    self.listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { continuation.resume(throwing: CancellationError()); return }
                        switch state {
                        case .ready:
                            self.listener.stateUpdateHandler = nil
                            guard let port = self.listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(self.target)") else {
                                continuation.resume(throwing: SMBError.invalidServer); return
                            }
                            continuation.resume(returning: url)
                        case .failed(let error): self.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                        case .cancelled: self.listener.stateUpdateHandler = nil; continuation.resume(throwing: CancellationError())
                        default: break
                        }
                    }
                    self.listener.start(queue: self.queue)
                }
            }
        } onCancel: { self.stop() }
    }

    func stop() {
        let cancel = {
            guard !self.stopped else { return }
            self.stopped = true; self.listener.cancel()
            self.tasks.values.forEach { $0.cancel() }; self.tasks.removeAll()
            self.clients.values.forEach { $0.cancel() }; self.clients.removeAll()
        }
        // Revocation is a barrier, not a queued intention. A suspended source read
        // may return immediately after this method returns and must not send bytes.
        if DispatchQueue.getSpecific(key: queueKey) != nil { cancel() }
        else { queue.sync(execute: cancel) }
    }

    private func accept(_ client: NWConnection) {
        guard !stopped, clients.count < 8 else { client.cancel(); return }
        let id = ObjectIdentifier(client); clients[id] = client
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close(id) }
            if case .cancelled = state { self?.close(id) }
        }
        client.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.tasks[id] == nil else { return }; self.close(id)
        }
        receive(client, prior: Data())
    }

    private func receive(_ client: NWConnection, prior: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: headerLimit - prior.count) { [weak self, weak client] bytes, _, complete, error in
            guard let self, let client else { return }
            let id = ObjectIdentifier(client)
            guard self.clients[id] === client, error == nil, let bytes, !bytes.isEmpty else { self.close(id); return }
            let data = prior + bytes
            if let terminator = data.range(of: Data("\r\n\r\n".utf8)) {
                guard terminator.upperBound == data.endIndex, let text = String(data: data[..<terminator.lowerBound], encoding: .utf8) else { self.close(id); return }
                let lines = text.components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                guard first.count == 3, first[0] == "GET" || first[0] == "HEAD", first[1] == self.target,
                      first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { self.close(id); return }
                var range: String?
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else { self.close(id); return }
                    let key = parts[0].lowercased(), value = parts[1].trimmingCharacters(in: .whitespaces)
                    if key == "range" { guard range == nil else { self.close(id); return }; range = value }
                    if key == "transfer-encoding" || key == "content-length" && value != "0" { self.close(id); return }
                }
                self.serve(client, range: range, headOnly: first[0] == "HEAD")
            } else if complete || data.count >= self.headerLimit { self.close(id) }
            else { self.receive(client, prior: data) }
        }
    }

    private func serve(_ client: NWConnection, range header: String?, headOnly: Bool) {
        let id = ObjectIdentifier(client)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                guard await self.authorize() else { throw PlaybackPreparationError.fileUnavailable }
                let size = try await self.reader.size()
                guard await self.authorize() else { throw PlaybackPreparationError.fileUnavailable }
                let range: Range
                do { range = try Range.parse(header, size: size) }
                catch {
                    let response = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(max(0, size))\r\nContent-Length: 0\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
                    try await self.send(Data(response.utf8), client: client, final: true)
                    self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.close(id) }
                    return
                }
                var response = "HTTP/1.1 \(header == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: application/octet-stream\r\nContent-Length: \(range.end - range.start)\r\nAccept-Ranges: bytes\r\nConnection: close\r\nCache-Control: no-store\r\n"
                if header != nil { response += "Content-Range: bytes \(range.start)-\(range.end - 1)/\(size)\r\n" }
                try await self.send(Data((response + "\r\n").utf8), client: client, final: headOnly)
                if !headOnly {
                    var offset = range.start
                    while offset < range.end {
                        try Task.checkCancellation()
                        guard await self.authorize() else { throw PlaybackPreparationError.fileUnavailable }
                        let count = Int(min(512 * 1024, range.end - offset))
                        let bytes = try await self.reader.read(offset, count)
                        guard !bytes.isEmpty, bytes.count <= count else { throw SMBError.unexpectedEndOfFile }
                        try Task.checkCancellation()
                        guard await self.authorize() else { throw PlaybackPreparationError.fileUnavailable }
                        offset += Int64(bytes.count)
                        try await self.send(bytes, client: client, final: offset == range.end)
                    }
                }
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.close(id) }
            } catch {
                self.queue.async { [weak self] in self?.close(id) }
            }
        }
    }

    private func send(_ data: Data, client: NWConnection, final: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Complete each logical send before switching contexts. TCP holds a different
            // context until its predecessor completes; leaving defaultMessage incomplete
            // would strand the final body chunk/FIN and make readers wait forever.
            queue.async {
                guard !self.stopped, self.clients[ObjectIdentifier(client)] === client else {
                    continuation.resume(throwing: CancellationError()); return
                }
                client.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                            completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }
    }
    private func close(_ id: ObjectIdentifier) {
        tasks.removeValue(forKey: id)?.cancel(); clients.removeValue(forKey: id)?.cancel()
    }
}
