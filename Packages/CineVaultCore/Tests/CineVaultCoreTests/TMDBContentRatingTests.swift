import Foundation
import XCTest
@testable import CineVaultCore

final class TMDBContentRatingTests: XCTestCase {
    func testMovieCertificationUsesUSAndMostRestrictiveKnownRelease() throws {
        let json = #"{"results":[{"iso_3166_1":"GB","release_dates":[{"certification":"18"}]},{"iso_3166_1":"US","release_dates":[{"certification":""},{"certification":"PG"},{"certification":"R"},{"certification":"PG-13"}]}]}"#
        let value = try TMDB.decoder.decode(TMDBMovieReleaseDates.self, from: Data(json.utf8))
        XCTAssertEqual(value.usContentRating, "R")
    }

    func testTVOnlyUsesUSCertificationsAndConservativelyCombinesEntries() throws {
        let json = #"{"results":[{"iso_3166_1":"GB","rating":"18"},{"iso_3166_1":"US","rating":"TV-G"},{"iso_3166_1":"US","rating":"TV-Y7-FV"}]}"#
        let value = try TMDB.decoder.decode(TMDBTVContentRatings.self, from: Data(json.utf8))
        XCTAssertEqual(value.usContentRating, "TV-Y7")
        XCTAssertEqual(TMDBUSContentRating.mostRestrictive(["TV-PG", "TV-MA", "TV-14"], television: true), "TV-MA")
    }

    func testUnknownAndForeignRatingsDoNotBecomeAllAges() throws {
        let unknown = #"{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"NR"},{"certification":"Unrated"},{"certification":"12"}]}]}"#
        XCTAssertNil(try TMDB.decoder.decode(TMDBMovieReleaseDates.self, from: Data(unknown.utf8)).usContentRating)
        let foreign = #"{"results":[{"iso_3166_1":"GB","rating":"TV-G"}]}"#
        XCTAssertNil(try TMDB.decoder.decode(TMDBTVContentRatings.self, from: Data(foreign.utf8)).usContentRating)
        XCTAssertNil(TMDBUSContentRating.mostRestrictive(["8.7", "PG-13"], television: true))
        XCTAssertNil(TMDBUSContentRating.mostRestrictive(["TV-G"], television: false))
    }

    func testSuccessfulEmptyCanBeDistinguishedFromAbsentAndMalformedPayload() throws {
        let absent = try TMDB.decoder.decode(TMDBMovieDetails.self, from: Data(#"{"id":1,"title":"Example","vote_average":8.9}"#.utf8))
        XCTAssertNil(absent.releaseDates)
        let empty = try TMDB.decoder.decode(TMDBMovieDetails.self, from: Data(#"{"id":1,"title":"Example","release_dates":{"results":[]}}"#.utf8))
        XCTAssertNotNil(empty.releaseDates)
        XCTAssertNil(empty.releaseDates?.usContentRating)
        XCTAssertThrowsError(try TMDB.decoder.decode(TMDBMovieReleaseDates.self, from: Data(#"{"status_code":34}"#.utf8)))
        XCTAssertThrowsError(try TMDB.decoder.decode(TMDBTVContentRatings.self, from: Data(#"{"results":[{"iso_3166_1":"US"}]}"#.utf8)))
        XCTAssertThrowsError(try TMDB.decoder.decode(TMDBMovieDetails.self, from: Data(#"{"id":1,"title":"Example","release_dates":{"results":"invalid"}}"#.utf8)))
    }

    func testDetailsAppendRatingsAndDedicatedBackfillRequestsUseCorrectNamespaces() throws {
        func appended(_ url: URL?) throws -> String? {
            let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(url), resolvingAgainstBaseURL: false))
            return components.queryItems?.first { $0.name == "append_to_response" }?.value
        }
        XCTAssertEqual(try appended(TMDB.detailsRequest(id: 42, apiKey: "fixture").url), "release_dates")
        XCTAssertEqual(try appended(TMDB.tvDetailsRequest(id: 42, apiKey: "fixture").url), "content_ratings")
        XCTAssertEqual(TMDB.movieReleaseDatesRequest(id: 42, apiKey: "fixture").url?.path, "/3/movie/42/release_dates")
        XCTAssertEqual(TMDB.tvContentRatingsRequest(id: 42, apiKey: "fixture").url?.path, "/3/tv/42/content_ratings")
    }
}
