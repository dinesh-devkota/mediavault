import Foundation

/// Certification strings are independent of TMDB's numeric audience vote score.
/// Keep only the US rating system; another country's "12" is not a US rating.
public enum TMDBUSContentRating {
    private static let movieRatings = ["G", "PG", "PG-13", "R", "NC-17"]
    private static let televisionRatings = ["TV-Y", "TV-G", "TV-Y7", "TV-PG", "TV-14", "TV-MA"]

    public static func mostRestrictive(_ values: [String], television: Bool) -> String? {
        let ratings = television ? televisionRatings : movieRatings
        let recognized = values.compactMap { raw -> Int? in
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            // Fantasy violence is a descriptor of TV-Y7, never an all-ages rating.
            if television && value == "TV-Y7-FV" { value = "TV-Y7" }
            return ratings.firstIndex(of: value)
        }
        return recognized.max().map { ratings[$0] }
    }
}

public struct TMDBMovieReleaseDates: Codable, Sendable {
    public struct Country: Codable, Sendable {
        public struct Release: Codable, Sendable {
            public let certification: String
        }
        // JSONDecoder.convertFromSnakeCase converts iso_3166_1 to iso31661.
        public let iso31661: String
        public let releaseDates: [Release]
    }
    public let results: [Country]

    public var usContentRating: String? {
        TMDBUSContentRating.mostRestrictive(
            results.filter { $0.iso31661 == "US" }.flatMap { $0.releaseDates.map(\.certification) },
            television: false)
    }
}

public struct TMDBTVContentRatings: Decodable, Sendable {
    public struct Country: Decodable, Sendable {
        public let iso31661: String
        public let rating: String
    }
    public let results: [Country]

    public var usContentRating: String? {
        TMDBUSContentRating.mostRestrictive(
            results.filter { $0.iso31661 == "US" }.map(\.rating), television: true)
    }
}
