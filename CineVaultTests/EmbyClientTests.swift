import CineVaultCore
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
        let artwork = try await client.primaryImage(account, itemID: "movie-a", width: 342)
        XCTAssertEqual(artwork, Data("fixture-jpeg".utf8))
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
        XCTAssertEqual(playback.textSubtitles.map(\.id), [3])
        XCTAssertEqual(playback.textSubtitles.first?.language, "eng")
        let text = try await client.textSubtitle(account, playback: playback, index: 3, maximumBytes: 4096)
        XCTAssertNoThrow(try SubtitleDocument.parse(text))
        do {
            _ = try await client.textSubtitle(account, playback: playback, index: 4, maximumBytes: 4096)
            XCTFail("An unadvertised track should fail before the server request")
        } catch EmbyError.invalidResponse {}
        do {
            _ = try await client.textSubtitle(account, playback: playback, index: 3, maximumBytes: 8)
            XCTFail("Oversized text subtitle should be rejected")
        } catch EmbyError.invalidResponse {}
        try await client.report(account, playback: playback, event: .progress, positionMillis: 500)
        try await client.report(account, playback: playback, event: .stopped, positionMillis: 500)
        try await client.signOut(account)
    }

    func testCatalogKeepsCaseSensitiveIDsAndUsesSeriesRatingForEpisodes() throws {
        let data = Data("""
            [
                {"Id":"Video","Name":"Upstairs","Type":"Movie","ProductionYear":2023,"OfficialRating":"PG"},
                {"Id":"video","Name":"Downstairs","Type":"Movie","OfficialRating":"R"},
                {"Id":"show","Name":"Example Show","Type":"Series","OfficialRating":"tv-pg","ProviderIds":{"Tmdb":"101"}},
                {"Id":"pilot","Name":"Pilot","Type":"Episode","SeriesId":"show","ParentIndexNumber":1,"IndexNumber":1,"OfficialRating":"TV-MA"},
                {"Id":"photo","Name":"Family landscape","Type":"Photo"},
                {"Id":"bad","Name":"No episode number","Type":"Episode","SeriesId":"show","ParentIndexNumber":1},
                {"Id":"../bad","Name":"Unsafe ID","Type":"Movie"}
            ]
            """.utf8)
        let items = try JSONDecoder().decode([EmbyClient.Item].self, from: data)
        let itemsFromLibrary = EmbyCatalogEntry.media(items)
        let photos = itemsFromLibrary.filter(\.isPhoto)
        XCTAssertEqual(photos.map(\.path), ["emby-photos/photo.jpg"])
        XCTAssertEqual(try EmbySourceConnection.photoID(for: try XCTUnwrap(photos.first?.path)), "photo")
        XCTAssertThrowsError(try EmbySourceConnection.itemID(for: "emby-photos/photo.jpg"))
        let videos = itemsFromLibrary.filter { !$0.isPhoto }
        XCTAssertEqual(videos.map(\.id), ["Video", "video", "pilot"])
        XCTAssertEqual(videos.map(\.rating), ["PG", "R", "TV-PG"])
        XCTAssertEqual(videos.last?.seriesTitle, "Example Show")
        XCTAssertEqual(videos.last?.seriesTMDBID, 101)
        XCTAssertEqual(videos.last?.season, 1)
        XCTAssertEqual(videos.last?.episode, 1)
        XCTAssertEqual(try EmbySourceConnection.itemID(for: EmbySourceConnection.path("Video")), "Video")
        XCTAssertEqual(try EmbySourceConnection.itemID(for: EmbySourceConnection.path("video")), "video")
        XCTAssertThrowsError(try EmbySourceConnection.itemID(for: "other/Video.mp4"))
        XCTAssertThrowsError(try EmbySourceConnection.itemID(for: "emby/a/Video.mp4"))
    }

    func testProviderIdentifierDoesNotDetermineTheAgeRatingCategory() {
        let source = MediaSource(name: "Emby fixture", host: "https://emby.fixture.invalid",
                                 share: "library", rootPath: "", username: "fixture")
        source.sourceProtocol = "emby"
        let path = EmbySourceConnection.path("Media-S01E03")
        let movie = Movie(filePath: path, fileSize: 0, source: source)
        XCTAssertNil(movie.episodeInfo)
        movie.seriesTitle = "Fixture Show"
        movie.seasonNumber = 1
        movie.episodeNumber = 3
        XCTAssertEqual(movie.episodeInfo?.seriesTitle, "Fixture Show")
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

    @MainActor
    func testPlayerRangeReturnsBytesAndSuppressesAResponseAfterAccessChanges() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmbyFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let config = SourceConfig(id: UUID(), host: "https://emby.fixture.invalid/emby/", share: "library",
                                  rootPath: "", username: "viewer", password: "fixture-token", isEmby: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MediaVault.EmbyTests.\(UUID().uuidString)"))
        let household = HouseholdStore(defaults: defaults, read: { nil }, write: { _ in }, erase: {})
        let connection = try EmbySourceConnection(config: config, session: session)
        let path = EmbySourceConnection.path("movie-a")
        let playback = try await connection.directPlayback(path: path)
        var received = Data()
        var checks = 0
        var permitted = true
        let bytes = EmbyByteReader(connection: connection, playback: playback)
        let reader = SMBResourceLoader.Reader(size: { try await bytes.size() }, read: { try await bytes.read($0, $1) })
        let loader = SMBResourceLoader(config: config, path: path, household: household, reader: reader,
                                       stillAvailable: {
            checks += 1
            return permitted && checks <= 2
        })
        do {
            try await loader.streamBytes(from: 5, to: 9) { received.append($0) }
            XCTFail("Expected access to be revoked before the bytes were delivered")
        } catch PlaybackPreparationError.fileUnavailable {}
        XCTAssertEqual(checks, 3)
        XCTAssertTrue(received.isEmpty)
        let permittedLoader = SMBResourceLoader(config: config, path: path, household: household, reader: reader,
                                                stillAvailable: { permitted })
        try await permittedLoader.streamBytes(from: 5, to: 9) { received.append($0) }
        XCTAssertEqual(received, Data("5678".utf8))
        permitted = false
        do {
            try await permittedLoader.streamBytes(from: 5, to: 9) { _ in XCTFail("Denied read sent bytes") }
            XCTFail("Expected authorization to be checked before a subsequent seek")
        } catch PlaybackPreparationError.fileUnavailable {}
    }

    func testTranscodeUsesScopedURLsAndHandlesBoundedSegmentRanges() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EmbyFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try EmbyClient(endpoint: "https://emby.fixture.invalid/emby", deviceID: "fixture-device",
                                    appVersion: "1.0", session: session)
        let account = try await client.signIn(username: "Viewer", password: "fixture-password")
        do {
            _ = try await client.directPlayback(account, itemID: "movie-hls", containers: ["mp4"], directVideoCodecs: ["h264", "hevc"])
            XCTFail("MPEG-2 in an otherwise accepted container should fall back to transcode")
        } catch EmbyError.unsupportedPlayback {}

        let playback = try await client.negotiateTranscode(account, itemID: "movie-hls")
        let components = try XCTUnwrap(URLComponents(url: playback.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/emby/Videos/movie-hls/master.m3u8")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(Set(query.keys), ["VideoCodec", "DeviceId", "MediaSourceId", "PlaySessionId"])
        XCTAssertEqual(query["VideoCodec"], "h264")
        XCTAssertEqual(query["PlaySessionId"], "transcode-session")
        XCTAssertEqual(query["MediaSourceId"], "fixture-source")
        XCTAssertNotNil(UUID(uuidString: query["DeviceId"] ?? ""))
        let next = try await client.negotiateTranscode(account, itemID: "movie-hls")
        XCTAssertNotEqual(next.url, playback.url)
        try await client.stopTranscode(account, playback: next)

        let manifest = try await client.readHLS(playback.url, account: account, playback: playback, range: nil)
        XCTAssertTrue(manifest.data.starts(with: Data("#EXTM3U".utf8)))
        XCTAssertNil(manifest.contentRange)
        let segment = try client.hlsResource("hls1/main/0.ts?api-key=alternate-token&start=0",
                                             relativeTo: playback.url, account: account, playback: playback)
        XCTAssertFalse(segment.absoluteString.contains("alternate-token"))
        let response = try await client.readHLS(segment, account: account, playback: playback, range: "bytes=2-4")
        XCTAssertEqual(response.data, Data("234".utf8))
        XCTAssertEqual(response.contentRange, "bytes 2-4/10")
        let complete = try await client.readHLS(segment, account: account, playback: playback, range: "bytes=8-")
        XCTAssertEqual(complete.data, Data("89".utf8))
        XCTAssertEqual(complete.contentRange, "bytes 8-9/10")
        let bad = try client.hlsResource("hls1/main/bad.ts", relativeTo: playback.url, account: account, playback: playback)
        do {
            _ = try await client.readHLS(bad, account: account, playback: playback, range: "bytes=2-4")
            XCTFail("An unrelated Content-Range is invalid")
        } catch EmbyError.invalidRange {}
        XCTAssertEqual(playback.textSubtitles.map(\.id), [3])
        let text = try await client.textSubtitle(account, playback: playback, index: 3, maximumBytes: 4096)
        XCTAssertNoThrow(try SubtitleDocument.parse(text))
        try await client.report(account, playback: playback, event: .started, positionMillis: 0)
        try await client.report(account, playback: playback, event: .stopped, positionMillis: 800)
        try await client.stopTranscode(account, playback: playback)
    }

    func testHLSScopeRejectsDifferentAccountsAndUnsafeChildAddresses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmbyFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try EmbyClient(endpoint: "https://emby.fixture.invalid/emby", deviceID: "fixture-device",
                                    appVersion: "1.0", session: session)
        let account = try await client.signIn(username: "Viewer", password: "fixture-password")
        let playback = try await client.negotiateTranscode(account, itemID: "movie-hls")
        let differentAccount = EmbyClient.Account(AccessToken: account.AccessToken, User: .init(Id: "other-user", Name: "Other"))
        XCTAssertThrowsError(try client.hlsResource("variant.m3u8", relativeTo: playback.url, account: differentAccount, playback: playback))
        for reference in [
            "http://emby.fixture.invalid/emby/Videos/movie-hls/variant.m3u8",
            "https://different.fixture.invalid/Videos/movie-hls/variant.m3u8",
            "https://emby.fixture.invalid:8443/Videos/movie-hls/variant.m3u8",
            "https://user@emby.fixture.invalid/Videos/movie-hls/variant.m3u8",
            "/Videos/movie-hls/variant.m3u8#fragment",
            "/Videos/MOVIE-HLS/variant.m3u8",
            "/Videos/movie-hls/nested%2Fvariant.m3u8",
            "/Videos/movie-hls/%66ixture-token.ts",
            "/Videos/movie-hls/../../Users/viewer",
        ] {
            XCTAssertThrowsError(try client.hlsResource(reference, relativeTo: playback.url, account: account, playback: playback), reference)
        }
        try await client.stopTranscode(account, playback: playback)
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
        case "/emby/Items/movie-a/Images/Primary":
            guard query["MaxWidth"] == "342", query["MaxHeight"] == "684", query["Format"] == "Jpg",
                  request.value(forHTTPHeaderField: "Accept") == "image/jpeg" else { return failure }
            return (200, "fixture-jpeg", ["Content-Type": "image/jpeg"])
        case "/emby/Items/movie-hls/PlaybackInfo":
            guard query["UserId"] == "viewer" else { return failure }
            if request.httpMethod == "GET" {
                return (200, #"{"PlaySessionId":"direct-session","MediaSources":[{"Id":"fixture-source","Container":"mp4","SupportsDirectPlay":true,"MediaStreams":[{"Type":"Video","Codec":"mpeg2video"}]}]}"#, [:])
            }
            guard request.httpMethod == "POST", UUID(uuidString: query["DeviceId"] ?? "") != nil else { return failure }
            return (200, #"{"PlaySessionId":"transcode-session","MediaSources":[{"Id":"fixture-source","TranscodingUrl":"/Videos/movie-hls/master.m3u8?VideoCodec=h264&api_key=discard&%2558-Emby-Token=discard&Other=%2566ixture-token&fixture-token=discard&DeviceId=wrong&MediaSourceId=wrong&PlaySessionId=wrong","MediaStreams":[{"Type":"Subtitle","Index":3,"IsTextSubtitleStream":true,"IsExternal":true,"Language":"eng","DisplayTitle":"English (SRT)"}]}]}"#, [:])
        case "/emby/Videos/movie-hls/master.m3u8":
            guard query["VideoCodec"] == "h264", query["PlaySessionId"] == "transcode-session",
                  query["MediaSourceId"] == "fixture-source", UUID(uuidString: query["DeviceId"] ?? "") != nil else { return failure }
            return (200, "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=160000\nvariant.m3u8\n", ["Content-Type": "application/vnd.apple.mpegurl"])
        case "/emby/Videos/movie-hls/hls1/main/0.ts":
            guard query["PlaySessionId"] == "transcode-session", query["MediaSourceId"] == "fixture-source",
                  UUID(uuidString: query["DeviceId"] ?? "") != nil,
                  request.value(forHTTPHeaderField: "Accept-Encoding") == "identity" else { return failure }
            switch request.value(forHTTPHeaderField: "Range") {
            case "bytes=2-4": return (206, "234", ["Content-Range": "bytes 2-4/10"])
            case "bytes=8-": return (200, "0123456789", [:])
            default: return failure
            }
        case "/emby/Videos/movie-hls/hls1/main/bad.ts":
            return (206, "345", ["Content-Range": "bytes 3-5/10"])
        case "/emby/Videos/ActiveEncodings":
            guard request.httpMethod == "DELETE", query["PlaySessionId"] == "transcode-session",
                  UUID(uuidString: query["DeviceId"] ?? "") != nil else { return failure }
            return (204, "", [:])
        case "/emby/Items/movie-a/PlaybackInfo":
            guard query["UserId"] == "viewer" else { return failure }
            return (200, #"{"PlaySessionId":"fixture-session","MediaSources":[{"Id":"fixture-source","Container":"mp4","SupportsDirectPlay":true,"MediaStreams":[{"Type":"Subtitle","Index":3,"IsTextSubtitleStream":true,"IsExternal":true,"Language":"eng","DisplayTitle":"English (SRT)"},{"Type":"Subtitle","Index":4,"IsTextSubtitleStream":false,"IsExternal":true}]}]}"#, [:])
        case "/emby/Videos/movie-a/fixture-source/Subtitles/3/Stream.srt",
             "/emby/Videos/movie-hls/fixture-source/Subtitles/3/Stream.srt":
            return (200, "1\n00:00:00,100 --> 00:00:02,500\nHello from Emby\n", ["Content-Type": "application/x-subrip"])
        case "/emby/Videos/movie-a/stream":
            guard query["Static"] == "true", query["MediaSourceId"] == "fixture-source",
                  query["PlaySessionId"] == "fixture-session",
                  let deviceID = query["DeviceId"],
                  deviceID == "fixture-device" || UUID(uuidString: deviceID) != nil else { return failure }
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
