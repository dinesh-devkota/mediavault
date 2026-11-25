import Foundation
import XCTest
@testable import CineVaultCore

final class LocalMediaMetadataTests: XCTestCase {
    private func parse(_ xml: String) throws -> LocalMediaMetadata { try LocalMetadataParser.parse(Data(xml.utf8)) }

    func testMovieDetailsCollectionAndEditionWithoutOnlineAccount() throws {
        let value = try parse("""
        <movie><title>Local &amp; Personal</title><plot><![CDATA[Home <story>]]></plot><year>2020</year>
        <genre>Drama / Documentary</genre><genre>Drama</genre><runtime>95</runtime><mpaa>US:PG</mpaa>
        <uniqueid type="tmdb">42</uniqueid><set><name>Local Saga</name></set><edition>Director's cut</edition>
        <thumb>https://untrusted.invalid/poster.jpg</thumb><resume><position>90</position></resume></movie>
        """)
        XCTAssertEqual(value.title, "Local & Personal"); XCTAssertEqual(value.plot, "Home <story>")
        XCTAssertEqual(value.year, 2020); XCTAssertEqual(value.genres, ["Drama", "Documentary"])
        XCTAssertEqual(value.tmdbID, 42); XCTAssertEqual(value.collection, "Local Saga")
        XCTAssertEqual(value.edition, "Director's cut"); XCTAssertEqual(value.certification, "PG")
        XCTAssertTrue(value.certificationPresent)
    }

    func testEpisodeAndDateFieldsAndUnknownCertification() throws {
        let value = try parse("<episodedetails><title>Pilot</title><showtitle>Home Show</showtitle><aired>2022-03-10</aired><season>0</season><episode>2</episode><certification>Not Rated</certification></episodedetails>")
        XCTAssertEqual(value.showTitle, "Home Show"); XCTAssertEqual(value.season, 0); XCTAssertEqual(value.episode, 2)
        XCTAssertEqual(value.year, 2022); XCTAssertTrue(value.certificationPresent); XCTAssertNil(value.certification)
    }

    func testRejectsDTDExternalEntitiesUTF16MalformedAndOversizedDocuments() throws {
        for xml in ["<!DOCTYPE movie [<!ENTITY x SYSTEM 'file:///private'>]><movie><title>&x;</title></movie>",
                    "<!DOCTYPE movie [<!ENTITY x 'boom'>]><movie><title>&x;</title></movie>",
                    "<movie><title>Broken</movie>", "<html><title>Sign in</title></html>"] {
            XCTAssertThrowsError(try parse(xml))
        }
        XCTAssertThrowsError(try LocalMetadataParser.parse(Data("<movie/>".utf16.map { UInt8(truncatingIfNeeded: $0) }.flatMap { [$0, 0] })))
        XCTAssertThrowsError(try LocalMetadataParser.parse(Data(repeating: 65, count: LocalMetadataParser.maximumBytes + 1)))
    }

    func testDepthLimitNestedFieldIsolationAndInvalidNumbers() throws {
        XCTAssertThrowsError(try parse("<movie>" + String(repeating: "<x>", count: 33) + String(repeating: "</x>", count: 33) + "</movie>"))
        let value = try parse("<movie><title>Movie</title><actor><title>Wrong</title></actor><year>0</year><runtime>-5</runtime><uniqueid type='imdb'>123</uniqueid><season>1000</season></movie>")
        XCTAssertEqual(value.title, "Movie"); XCTAssertNil(value.tmdbID); XCTAssertNil(value.year); XCTAssertNil(value.runtime); XCTAssertNil(value.season)
    }

    func testArtworkCandidatesDoNotGuessAcrossSharedMovieFolders() {
        XCTAssertEqual(LocalMediaSidecars.metadataCandidates(video: "Movies/Film.mkv", singleVideo: false), ["Movies/Film.nfo", "Movies/Film.xml"])
        XCTAssertFalse(LocalMediaSidecars.artworkCandidates(video: "Movies/Film.mkv", backdrop: false, singleVideo: false).contains("Movies/poster.jpg"))
        XCTAssertTrue(LocalMediaSidecars.artworkCandidates(video: "Movies/Film.mkv", backdrop: false, singleVideo: true).contains("Movies/poster.png"))
        XCTAssertTrue(LocalMediaSidecars.artworkCandidates(video: "Movies/Film.mkv", backdrop: true, singleVideo: false).contains("Movies/Film-fanart.webp"))
    }

    func testTMDBCollectionDecodesFromDetails() throws {
        let details = try TMDB.decoder.decode(TMDBMovieDetails.self, from: Data(#"{"id":42,"title":"Film","belongs_to_collection":{"id":12,"name":"Film Collection"}}"#.utf8))
        XCTAssertEqual(details.belongsToCollection?.id, 12)
        XCTAssertEqual(details.belongsToCollection?.name, "Film Collection")
    }
}
