import Foundation
import XCTest
@testable import CineVault

final class EmbyClientTests: XCTestCase {
    func testFixtureSignsInPaginatesNegotiatesSeeksReportsAndSignsOut() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EmbyFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try EmbyClient(endpoint: "https://emby.fixture.invalid/emby/", deviceID: "fixture-device",
                                    appVersion: "1.0", session: session)

        let account = try await client.signIn(username: "Viewer", password: "fixture-password")
        let libraries = try await client.libraries(account)
        XCTAssertEqual(libraries.map { $0.Name }, ["Movies"])
        var movieTitles = [String]()
        try await client.catalog(account, libraryID: "library") { page in
            movieTitles += page.map { $0.Name }
        }
        XCTAssertEqual(movieTitles, ["One", "Two"])
        let playback = try await client.directPlayback(account, itemID: "movie-a", containers: ["mp4"])
        XCTAssertEqual(playback.container, "mp4")
        try await client.report(account, playback: playback, event: .started, positionMillis: 0)
        let range = try await client.read(account, playback: playback, offset: 5, length: 4)
        XCTAssertEqual(range.totalLength, 20)
        XCTAssertEqual(range.bytes, Data("5678".utf8))
        try await client.report(account, playback: playback, event: .progress, positionMillis: 500)
        try await client.report(account, playback: playback, event: .stopped, positionMillis: 500)
        try await client.signOut(account)
    }

    func testCatalogKeepsCaseSensitiveIDsAndUsesSeriesRatingForEpisodes() throws {
        let data = Data("""
            [
                {"Id":"Video","Name":"Upstairs","Type":"Movie","ProductionYear":2023,"OfficialRating":"PG"},
                {"Id":"video","Name":"Downstairs","Type":"Movie","OfficialRating":"R"},
                {"Id":"show","Name":"Example Show","Type":"Series","OfficialRating":"tv-pg"},
                {"Id":"pilot","Name":"Pilot","Type":"Episode","SeriesId":"show","ParentIndexNumber":1,"IndexNumber":1,"OfficialRating":"TV-MA"},
                {"Id":"bad","Name":"No episode number","Type":"Episode","SeriesId":"show","ParentIndexNumber":1},
                {"Id":"../bad","Name":"Unsafe ID","Type":"Movie"}
            ]
            """.utf8)
        let items = try JSONDecoder().decode([EmbyClient.Item].self, from: data)
        let videos = EmbyCatalogVideo.videos(items)
        XCTAssertEqual(videos.map(\.id), ["Video", "video", "pilot"])
        XCTAssertEqual(videos.map(\.rating), ["PG", "R", "TV-PG"])
        XCTAssertEqual(videos.last?.seriesTitle, "Example Show")
        XCTAssertEqual(videos.last?.season, 1)
        XCTAssertEqual(videos.last?.episode, 1)
        XCTAssertEqual(try EmbySourceConnection.itemID(for: EmbySourceConnection.path("Video")), "Video")
        XCTAssertEqual(try EmbySourceConnection.itemID(for: EmbySourceConnection.path("video")), "video")
        XCTAssertThrowsError(try EmbySourceConnection.itemID(for: "other/Video.mp4"))
        XCTAssertThrowsError(try EmbySourceConnection.itemID(for: "emby/a/Video.mp4"))
    }

    func testEmbyRequiresAnExplicitEntireLibraryGrant() {
        let sourceID = UUID()
        var viewer = HouseholdProfile(name: "Viewer")
        let canRead = { (profile: HouseholdProfile) in
            HouseholdPolicy.allowsPath(profile: profile, sourceID: sourceID, path: "emby/Video.mp4", entireSourceOnly: true)
        }
        XCTAssertFalse(canRead(viewer))
        viewer.allowedFolders = [HouseholdFolder(sourceID: sourceID, path: "emby")]
        XCTAssertFalse(canRead(viewer))
        viewer.allowedFolders = [HouseholdFolder(sourceID: UUID(), path: "")]
        XCTAssertFalse(canRead(viewer))
        viewer.allowedFolders = [HouseholdFolder(sourceID: sourceID, path: "")]
        XCTAssertTrue(canRead(viewer))
    }

    func testFixtureRejectsUnrangedOrMalformedResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EmbyFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try EmbyClient(endpoint: "https://emby.fixture.invalid/emby/", deviceID: "fixture-device",
                                    appVersion: "1.0", session: session)
        let account = try await client.signIn(username: "Viewer", password: "fixture-password")
        let playback = try await client.directPlayback(account, itemID: "movie-a", containers: ["mp4"])
        for offset: Int64 in [0, 1] {
            do {
                _ = try await client.read(account, playback: playback, offset: offset, length: 4)
                XCTFail("Expected an invalid byte range at offset \(offset)")
            } catch EmbyError.invalidRange {}
        }
    }
}

private final class EmbyFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "emby.fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let result = route()
        let data = Data(result.body.utf8)
        var headers = result.headers
        headers["Content-Length"] = String(data.count)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func route() -> (status: Int, body: String, headers: [String: String]) {
        let failure: (Int, String, [String: String]) = (400, "", [:])
        guard let url = request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Emby ") == true else { return failure }
        let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })
        if parts.path == "/emby/Users/AuthenticateByName" {
            guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "X-Emby-Token") == nil else { return failure }
            return (200, #"{"AccessToken":"fixture-token","User":{"Id":"viewer","Name":"Viewer"}}"#, [:])
        }
        guard request.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token",
              !url.absoluteString.contains("fixture-token") else { return failure }
        switch parts.path {
        case "/emby/Users/viewer/Views":
            return (200, #"{"Items":[{"Id":"library","Name":"Movies","Type":"CollectionFolder"}]}"#, [:])
        case "/emby/Users/viewer/Items":
            guard query["ParentId"] == "library", query["EnableUserData"] == "false" else { return failure }
            if query["StartIndex"] == "0" {
                return (200, #"{"Items":[{"Id":"movie-a","Name":"One","Type":"Movie"}],"TotalRecordCount":2}"#, [:])
            }
            if query["StartIndex"] == "1" {
                return (200, #"{"Items":[{"Id":"movie-b","Name":"Two","Type":"Movie"}],"TotalRecordCount":2}"#, [:])
            }
        case "/emby/Items/movie-a/PlaybackInfo":
            guard query["UserId"] == "viewer" else { return failure }
            return (200, #"{"PlaySessionId":"fixture-session","MediaSources":[{"Id":"fixture-source","Container":"mp4","SupportsDirectPlay":true}]}"#, [:])
        case "/emby/Videos/movie-a/stream":
            guard query["Static"] == "true", query["MediaSourceId"] == "fixture-source",
                  query["PlaySessionId"] == "fixture-session", query["DeviceId"] == "fixture-device" else { return failure }
            switch request.value(forHTTPHeaderField: "Range") {
            case "bytes=5-8": return (206, "5678", ["Content-Range": "bytes 5-8/20"])
            case "bytes=0-3": return (200, "0123", [:])
            case "bytes=1-4": return (206, "1234", ["Content-Range": "bytes 1-4/4"])
            default: return failure
            }
        case "/emby/Sessions/Playing", "/emby/Sessions/Playing/Progress", "/emby/Sessions/Playing/Stopped",
             "/emby/Sessions/Logout":
            if request.httpMethod == "POST" { return (204, "", [:]) }
        default:
            break
        }
        return failure
    }
}
