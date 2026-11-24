import Foundation
import XCTest
@testable import CineVault

final class SubDLClientTests: XCTestCase {
    private let movie = SubDLSearchQuery(tmdbID: 27205, type: .movie)

    func testSearchUsesBearerAndExactIdentityQuery() async throws {
        let data = try fixture(files: [file()])
        let client = SubDLClient { request, maximum in
            XCTAssertEqual(maximum, 2 * 1_024 * 1_024)
            XCTAssertEqual(request.url?.host, "api.subdl.com")
            XCTAssertEqual(request.url?.path, "/api/v2/subtitles/search")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
            XCTAssertFalse(request.url!.absoluteString.contains("test-secret"))
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
            XCTAssertEqual(query["tmdb_id"], "27205")
            XCTAssertEqual(query["type"], "movie")
            XCTAssertEqual(query["languages"], "en")
            XCTAssertEqual(query["unpack"], "1")
            XCTAssertEqual(query["full_season"], "0")
            XCTAssertEqual(query["releases"], "1")
            XCTAssertEqual(query["client"], "custom_integration")
            XCTAssertEqual(query["subs_per_page"], "30")
            return SubDLHTTPResponse(statusCode: 200, url: request.url!, data: data)
        }
        let results = try await client.search(movie, apiKey: "test-secret")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].language, "en")
        XCTAssertEqual(results[0].format, "srt")
        XCTAssertEqual(results[0].fps, 23.976)
        XCTAssertTrue(results[0].releaseNames.contains("Alternate.Release"))
    }

    func testFallbackCannotUseMatchingSecondIdentity() async throws {
        let body = try fixture(files: [file()], identities: [
            ["tmdb_id": 9, "type": "movie"], ["tmdb_id": 27205, "type": "movie"]
        ])
        await assertFailure(.noResults) { _ = try await self.client(body).search(self.movie, apiKey: "key") }
        let wrongType = try fixture(files: [file()], identities: [["tmdb_id": 27205, "type": "tv"]])
        await assertFailure(.noResults) { _ = try await self.client(wrongType).search(self.movie, apiKey: "key") }
    }

    func testTVRequiresExactIdentityOnIndividualFile() async throws {
        var ambiguous = file(id: "ambiguous", season: 1, episode: 2)
        ambiguous.removeValue(forKey: "episode")
        let data = try fixture(files: [file(id: "right", season: 1, episode: 2),
                                      file(id: "wrong", season: 1, episode: 20), ambiguous],
                               identities: [["tmdb_id": 42, "type": "tv"]])
        let client = SubDLClient { request, _ in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "season" }?.value, "1")
            XCTAssertEqual(items.first { $0.name == "episode" }?.value, "2")
            return SubDLHTTPResponse(statusCode: 200, url: request.url!, data: data)
        }
        let results = try await client.search(SubDLSearchQuery(tmdbID: 42, type: .tv, season: 1, episode: 2), apiKey: "key")
        XCTAssertEqual(results.map(\.downloadURL.lastPathComponent), ["right"])
    }

    func testFiltersOtherLanguagesFormatsAndMismatchedFileIDs() async throws {
        var wrongID = file(id: "wrong-id")
        wrongID["url"] = "/subtitle/parent/other-id"
        let data = try fixture(files: [file(), file(id: "french", language: "FR"),
                                      file(id: "archive", format: "zip"), wrongID])
        let results = try await client(data).search(movie, apiKey: "key")
        XCTAssertEqual(results.count, 1)
    }

    func testRejectsUnsafeLinksAndArchives() {
        let unsafe = ["http://dl.subdl.com/subtitle/p/f", "https://evil.example/subtitle/p/f",
                      "https://dl.subdl.com.evil.example/subtitle/p/f", "https://user@dl.subdl.com/subtitle/p/f",
                      "https://dl.subdl.com:443/subtitle/p/f", "//evil.example/subtitle/p/f",
                      "/subtitle/p/f?api_key=secret", "/subtitle/p/f#part", "/subtitle/p.zip",
                      "/subtitle/p/%2e%2e", "/subtitle/../f", "/subtitle/p/f/extra"]
        for value in unsafe { XCTAssertNil(SubDLClient.safeDownloadURL(value), value) }
        XCTAssertEqual(SubDLClient.safeDownloadURL("/subtitle/parent/file_1")?.host, "dl.subdl.com")
    }

    func testDownloadsAreAnonymousAndBounded() async throws {
        let contents = Data("1\n00:00:00,000 --> 00:00:01,000\nHello\n".utf8)
        let client = SubDLClient { request, maximum in
            XCTAssertEqual(request.url?.host, "dl.subdl.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(maximum, SubDLClient.maximumBytes)
            return SubDLHTTPResponse(statusCode: 200, url: request.url!, data: contents)
        }
        let actual = try await client.download(subtitle())
        XCTAssertEqual(actual, contents)
        await assertFailure(.tooLarge) {
            _ = try await self.client(Data(repeating: 65, count: SubDLClient.maximumBytes + 1)).download(self.subtitle())
        }
        await assertFailure(.invalidResponse) { _ = try await self.client(Data([0x50, 0x4b, 3, 4])).download(self.subtitle()) }
    }

    func testRejectsRedirectsAndChangedFinalHost() async {
        await assertFailure(.unsafeDownload) { _ = try await self.client(Data(), status: 302).download(self.subtitle()) }
        let redirected = SubDLClient { _, _ in
            SubDLHTTPResponse(statusCode: 200, url: URL(string: "https://evil.example/file")!, data: Data("secret".utf8))
        }
        await assertFailure(.unsafeDownload) { _ = try await redirected.download(self.subtitle()) }
    }

    func testKeyValidationRequiresAccountShapeAndUsesSafeHeader() async throws {
        let client = SubDLClient { request, _ in
            XCTAssertEqual(request.url?.path, "/api/v2/me")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
            return SubDLHTTPResponse(statusCode: 200, url: request.url!, data: Data(#"{"plan":{"name":"Free"},"usage":{"search":{}}}"#.utf8))
        }
        try await client.validateKey("key")
        await assertFailure(.invalidResponse) { try await self.client(Data("{}".utf8)).validateKey("key") }
        await assertFailure(.invalidKey) { try await client.validateKey("key\r\nHeader: injected") }
    }

    func testHTTPFailuresAndServerTextNeverExposeSecrets() async {
        for (status, expected) in [(401, SubDLError.invalidKey), (403, .invalidKey), (429, .quota), (500, .connection)] {
            await assertFailure(expected) {
                try await self.client(Data("secret-key http://nas/password".utf8), status: status).validateKey("key")
            }
            XCTAssertFalse(expected.localizedDescription.contains("secret-key"))
        }
        let data = Data(#"{"error":{"code":"quota_exceeded","message":"secret-key"}}"#.utf8)
        await assertFailure(.quota) { try await self.client(data).validateKey("key") }
    }

    func testCancellationPropagates() async {
        let client = SubDLClient { _, _ in throw CancellationError() }
        do { try await client.validateKey("key"); XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Cancellation was replaced") }
    }

    private func assertFailure(_ expected: SubDLError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch let error as SubDLError { XCTAssertEqual(error, expected) }
        catch { XCTFail("Unexpected error type") }
    }

    private func client(_ data: Data, status: Int = 200) -> SubDLClient {
        SubDLClient { request, _ in SubDLHTTPResponse(statusCode: status, url: request.url!, data: data) }
    }

    private func subtitle() -> SubDLSubtitle {
        SubDLSubtitle(id: "file", language: "en", releaseName: "Release", format: "srt", hearingImpaired: false,
                      downloadURL: URL(string: "https://dl.subdl.com/subtitle/parent/file")!, fps: nil)
    }

    private func file(id: String = "file", season: Int = 0, episode: Int = 0,
                      language: String = "EN", format: String = "srt") -> [String: Any] {
        ["file_n_id": id, "language": language, "format": format, "season": season, "episode": episode,
         "release_name": "Exact.Release", "size": 100, "hi": true, "url": "/subtitle/parent/\(id)"]
    }

    private func fixture(files: [[String: Any]], identities: [[String: Any]]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "status": true, "results": identities ?? [["tmdb_id": 27205, "type": "movie"]],
            "subtitles": [["release_name": "Archive", "fps": "23.976", "releases": ["Alternate.Release"],
                           "unpack_files": files, "url": "/subtitle/archive.zip"]]
        ])
    }
}
