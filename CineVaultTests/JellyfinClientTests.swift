@testable import CineVault
import Foundation
import XCTest

final class JellyfinClientTests: XCTestCase {
    func testSignInAndPaginationKeepProviderHistoryOutOfImport() async throws {
        let client = try JellyfinClient(endpoint: "https://fixture.example/jellyfin/", deviceID: "device", version: "1.0") { request in
            let path = try XCTUnwrap(request.url?.path)
            switch path {
            case "/jellyfin/Users/AuthenticateByName":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertFalse(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=") ?? true)
                let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
                XCTAssertEqual(body, ["Username": "viewer", "Pw": "sample"])
                return (Data(#"{"AccessToken":"fixture-token","User":{"Id":"account","Name":"Viewer"}}"#.utf8), 200)
            case "/jellyfin/Items":
                XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("fixture-token") ?? false)
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "enableUserData" }?.value, "false")
                XCTAssertEqual(query?.first { $0.name == "parentId" }?.value, "library")
                if query?.first(where: { $0.name == "startIndex" })?.value == "0" {
                    return (Data(#"{"StartIndex":0,"TotalRecordCount":2,"Items":[{"Id":"show","Name":"Show","Type":"Series"}]}"#.utf8), 200)
                }
                return (Data(#"{"StartIndex":1,"TotalRecordCount":2,"Items":[{"Id":"episode","Name":"Pilot","Type":"Episode","SeriesId":"show","SeasonId":"season"}]}"#.utf8), 200)
            default:
                XCTFail("Unexpected Jellyfin request")
                return (Data(), 404)
            }
        }
        let account = try await client.signIn(username: "viewer", password: "sample")
        var items: [JellyfinCatalogItem] = []
        try await client.catalog(account, libraryID: "library") { items.append(contentsOf: $0) }
        XCTAssertEqual(items.map(\.id), ["show", "episode"])
        XCTAssertEqual(items.last?.seriesID, "show")
        XCTAssertEqual(items.last?.seasonID, "season")
    }

    func testPlaybackNegotiationKeepsTranscodeOnServerAndReportsSameSession() async throws {
        let client = try JellyfinClient(endpoint: "https://fixture.example/jellyfin/", deviceID: "device", version: "1.0") { request in
            switch try XCTUnwrap(request.url?.path) {
            case "/jellyfin/Users/AuthenticateByName":
                return (Data(#"{"AccessToken":"fixture-token","User":{"Id":"account","Name":"Viewer"}}"#.utf8), 200)
            case "/jellyfin/Items/movie/PlaybackInfo":
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["StartTimeTicks"] as? Int, 10_000_000)
                return (Data(#"{"PlaySessionId":"play","MediaSources":[{"Id":"source","TranscodingUrl":"/videos/movie/master.m3u8?api_key=hidden&PlaySessionId=play","MediaStreams":[{"Type":"Subtitle","Index":2,"IsTextSubtitleStream":true}]}]}"#.utf8), 200)
            case "/jellyfin/Sessions/Playing/Stopped":
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["PlaySessionId"] as? String, "play")
                XCTAssertEqual(json["PositionTicks"] as? Int, 20_000_000)
                return (Data(), 204)
            default:
                XCTFail("Unexpected Jellyfin request")
                return (Data(), 404)
            }
        }
        let account = try await client.signIn(username: "viewer", password: "sample")
        let playback = try await client.playback(account, itemID: "movie", startMillis: 1_000, deviceProfile: Data("{}".utf8))
        XCTAssertEqual(playback.method, .transcode)
        XCTAssertEqual(playback.url.absoluteString, "https://fixture.example/jellyfin/videos/movie/master.m3u8?PlaySessionId=play")
        XCTAssertEqual(playback.subtitles.map(\.index), [2])
        XCTAssertThrowsError(try client.assetRequest(XCTUnwrap(URL(string: "https://fixture.example/outside/segment.ts")), account: account))
        try await client.report(account, playback: playback, event: .stopped, positionMillis: 2_000)
    }

    func testHTTPAndHeaderInjectionAreRejected() {
        XCTAssertThrowsError(try JellyfinClient(endpoint: "http://fixture.example/", deviceID: "device", version: "1.0"))
        XCTAssertThrowsError(try JellyfinClient(endpoint: "https://fixture.example/", deviceID: "device\n", version: "1.0"))
    }

    func testVideoPathsUseScopedProviderIDsRatherThanCatalogTitles() throws {
        let data = Data(#"{"Id":"episode52","Name":"../share","Type":"Episode","SeriesId":"show3","SeriesName":"Show","ParentIndexNumber":0,"IndexNumber":2}"#.utf8)
        let item = try JSONDecoder().decode(JellyfinCatalogItem.self, from: data)
        let path = try XCTUnwrap(JellyfinSourceConnection.videoPath(item))
        XCTAssertEqual(path, "show3/0/episode52.mp4")
        XCTAssertEqual(try JellyfinSourceConnection.itemID(for: path), "episode52")
        XCTAssertThrowsError(try JellyfinSourceConnection.itemID(for: "season/..%2fsecret.mp4"))
        let ungrouped = Data(#"{"Id":"episode52","Name":"Episode","Type":"Episode"}"#.utf8)
        XCTAssertNil(JellyfinSourceConnection.videoPath(try JSONDecoder().decode(JellyfinCatalogItem.self, from: ungrouped)))
    }
}
