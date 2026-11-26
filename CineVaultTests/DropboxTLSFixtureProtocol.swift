import Foundation

/// Routes the two live Dropbox API hosts to the disposable HTTPS test server.
/// The production client continues using its fixed hosts and normal trust policy.
final class DropboxTLSFixtureProtocol: URLProtocol {
    private var transfer: URLSessionDataTask?

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return ["api.dropboxapi.com", "content.dropboxapi.com"].contains(url.host ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let original = request.url,
              var address = URLComponents(url: original, resolvingAgainstBaseURL: false) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        address.host = "127.0.0.1"
        address.port = 18444
        guard let url = address.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var local = request
        local.url = url
        local.setValue(nil, forHTTPHeaderField: "Host")
        if local.httpBody == nil, let stream = local.httpBodyStream {
            do { local.httpBody = try Self.body(stream) }
            catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }
        let transfer = URLSession.shared.dataTask(with: local) { [weak self] data, response, error in
            guard let self else { return }
            guard let data, let response else {
                client?.urlProtocol(self, didFailWithError: error ?? URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        self.transfer = transfer
        transfer.resume()
    }

    override func stopLoading() { transfer?.cancel() }

    private static func body(_ stream: InputStream) throws -> Data {
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0, result.count + count <= 16_384 else { throw URLError(.dataLengthExceedsMaximum) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
