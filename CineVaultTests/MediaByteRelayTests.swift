import Foundation
import XCTest
@testable import CineVault

final class MediaByteRelayTests: XCTestCase {
    func testRangeParsingBoundsAndSuffixes() throws {
        typealias R = MediaByteRelay.Range
        XCTAssertEqual(try R.parse(nil, size: 10), R(start: 0, end: 10))
        XCTAssertEqual(try R.parse("bytes=2-5", size: 10), R(start: 2, end: 6))
        XCTAssertEqual(try R.parse("bytes=7-", size: 10), R(start: 7, end: 10))
        XCTAssertEqual(try R.parse("bytes=-3", size: 10), R(start: 7, end: 10))
        XCTAssertEqual(try R.parse("bytes=-30", size: 10), R(start: 0, end: 10))
        XCTAssertEqual(try R.parse("bytes=7-9223372036854775807", size: 10), R(start: 7, end: 10))
        for invalid in ["bytes=10-", "bytes=-0", "bytes=2-1", "bytes=0-1,4-5", "bytes=0-9223372036854775808", "bytes=+-3", "items=0-3"] {
            XCTAssertThrowsError(try R.parse(invalid, size: 10), invalid)
        }
    }

    func testHTTPHeadAndClosedOpenSuffixAndEOFRanges() async throws {
        let source = RelaySource()
        let relay = try makeRelay(source)
        defer { relay.stop() }
        let url = try await relay.start()
        let cases: [(String?, String, Int, String?)] = [
            (nil, "0123456789", 200, nil), ("bytes=2-5", "2345", 206, "bytes 2-5/10"),
            ("bytes=7-", "789", 206, "bytes 7-9/10"), ("bytes=-2", "89", 206, "bytes 8-9/10"),
            ("bytes=10-", "", 416, "bytes */10"), ("bytes=4-2", "", 416, "bytes */10")
        ]
        for (range, expected, status, contentRange) in cases {
            var request = URLRequest(url: url); request.setValue(range, forHTTPHeaderField: "Range")
            let (data, raw) = try await session().data(for: request)
            let response = try XCTUnwrap(raw as? HTTPURLResponse)
            XCTAssertEqual(response.statusCode, status)
            XCTAssertEqual(String(data: data, encoding: .utf8), expected)
            XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), contentRange)
        }
        let beforeHead = await source.reads
        var head = URLRequest(url: url); head.httpMethod = "HEAD"
        let (data, raw) = try await session().data(for: head)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual((raw as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "10")
        let afterHead = await source.reads
        XCTAssertEqual(beforeHead, afterHead)
    }

    func testUnknownTokenNeverReadsSource() async throws {
        let source = RelaySource(); let relay = try makeRelay(source)
        defer { relay.stop() }
        let url = try await relay.start().deletingLastPathComponent().appendingPathComponent("other.mkv")
        do { _ = try await session().data(from: url); XCTFail("Unknown files must be rejected") } catch { }
        let sizes = await source.sizes, reads = await source.reads
        XCTAssertEqual(sizes, 0); XCTAssertEqual(reads, 0)
    }

    func testRevocationAfterDelayedReadDoesNotReleaseBody() async throws {
        let source = RelaySource(); await source.setRevokeOnRead()
        let relay = try makeRelay(source); defer { relay.stop() }
        let url = try await relay.start()
        do { _ = try await session().data(from: url); XCTFail("Revoked bytes must not reach the decoder") } catch { }
        let reads = await source.reads
        XCTAssertGreaterThan(reads, 0)
    }

    func testStopCancelsInflightRequest() async throws {
        let source = RelaySource(); await source.setBlockRead()
        let relay = try makeRelay(source); let url = try await relay.start()
        let request = Task { try await self.session().data(from: url) }
        let deadline = Date().addingTimeInterval(5)
        while await source.reads == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        relay.stop(); await source.releaseRead()
        do { _ = try await request.value; XCTFail("Stopped relay must cancel pending bytes") } catch { }
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 4
        return URLSession(configuration: config)
    }
    private func makeRelay(_ source: RelaySource) throws -> MediaByteRelay {
        try MediaByteRelay(fileExtension: "mkv", reader: .init(size: { await source.size() }, read: { offset, length in
            await source.read(offset: offset, length: length)
        }), authorize: { await source.allowed })
    }
}

private actor RelaySource {
    var allowed = true
    var sizes = 0
    var reads = 0
    private var revoke = false
    private var block = false
    private var waiter: CheckedContinuation<Void, Never>?
    func setRevokeOnRead() { revoke = true }
    func setBlockRead() { block = true }
    func releaseRead() { block = false; waiter?.resume(); waiter = nil }
    func size() -> Int64 { sizes += 1; return 10 }
    func read(offset: Int64, length: Int) async -> Data {
        reads += 1
        if block { await withCheckedContinuation { waiter = $0 } }
        if revoke { allowed = false }
        return Data("0123456789".utf8).subdata(in: Int(offset)..<min(10, Int(offset) + length))
    }
}
