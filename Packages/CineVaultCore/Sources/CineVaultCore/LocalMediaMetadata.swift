import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Supported read-only NFO/XML fields. Resume points, watched state and remote URLs are never imported.
public struct LocalMediaMetadata: Codable, Equatable, Sendable {
    public var kind: String
    public var title: String?
    public var showTitle: String?
    public var plot: String?
    public var tagline: String?
    public var year: Int?
    public var genres: [String] = []
    public var runtime: Int?
    public var certification: String?
    public var certificationPresent = false
    public var edition: String?
    public var tmdbID: Int?
    public var season: Int?
    public var episode: Int?
    public var collection: String?
    public init(kind: String) { self.kind = kind }
}

public enum LocalMetadataError: Error, Equatable {
    case tooLarge, invalidXML, unsafeXML, unsupportedRoot
}

public enum LocalMetadataParser {
    public static let maximumBytes = 1024 * 1024

    /// UTF-8 only, bounded and DTD/entity-free. NFO content is data, never instructions or fetch URLs.
    public static func parse(_ data: Data) throws -> LocalMediaMetadata {
        guard data.count <= maximumBytes else { throw LocalMetadataError.tooLarge }
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw LocalMetadataError.invalidXML }
        guard text.range(of: "<!\\s*(?:DOCTYPE|ENTITY)", options: [.regularExpression, .caseInsensitive]) == nil else {
            throw LocalMetadataError.unsafeXML
        }
        let delegate = MetadataDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, let result = delegate.metadata else {
            throw delegate.unsupported ? LocalMetadataError.unsupportedRoot : LocalMetadataError.invalidXML
        }
        return result
    }

    private final class MetadataDelegate: NSObject, XMLParserDelegate {
        var metadata: LocalMediaMetadata?
        var invalid = false
        var unsupported = false
        private var stack: [String] = []
        private var contents: [String] = []
        private var attributes: [[String: String]] = []
        private var elements = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            elements += 1
            guard stack.count < 32, elements <= 10_000 else { invalid = true; parser.abortParsing(); return }
            let name = elementName.lowercased()
            if stack.isEmpty {
                guard metadata == nil, ["movie", "episodedetails", "tvshow", "season"].contains(name) else {
                    unsupported = true; parser.abortParsing(); return
                }
                metadata = LocalMediaMetadata(kind: name)
            }
            stack.append(name); contents.append(""); attributes.append(attributeDict)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !contents.isEmpty else { return }
            guard contents[contents.count - 1].utf8.count + string.utf8.count <= 64 * 1024 else { invalid = true; parser.abortParsing(); return }
            contents[contents.count - 1] += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let value = String(data: CDATABlock, encoding: .utf8) else { invalid = true; parser.abortParsing(); return }
            self.parser(parser, foundCharacters: value)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let name = stack.last, let text = contents.last, let attribute = attributes.last else { invalid = true; return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                if stack.count == 2 {
                    switch name {
                    case "title": metadata?.title = String(value.prefix(500))
                    case "showtitle": metadata?.showTitle = String(value.prefix(500))
                    case "plot", "outline": if name == "plot" || metadata?.plot == nil { metadata?.plot = String(value.prefix(20_000)) }
                    case "tagline": metadata?.tagline = String(value.prefix(1000))
                    case "year": metadata?.year = Int(value).flatMap { (1800...2200).contains($0) ? $0 : nil }
                    case "premiered", "aired": if metadata?.year == nil { metadata?.year = Int(value.prefix(4)).flatMap { (1800...2200).contains($0) ? $0 : nil } }
                    case "genre":
                        for genre in value.components(separatedBy: " / ").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !genre.isEmpty {
                            if (metadata?.genres.count ?? 0) < 50, metadata?.genres.contains(genre) != true { metadata?.genres.append(String(genre.prefix(100))) }
                        }
                    case "runtime": metadata?.runtime = Int(value).flatMap { (1...10_000).contains($0) ? $0 : nil }
                    case "mpaa", "certification": metadata?.certificationPresent = true; metadata?.certification = certification(value)
                    case "edition": metadata?.edition = String(value.prefix(100))
                    case "tmdbid": metadata?.tmdbID = positive(value)
                    case "uniqueid": if attribute["type"]?.lowercased() == "tmdb" { metadata?.tmdbID = positive(value) }
                    case "season": metadata?.season = Int(value).flatMap { (0...999).contains($0) ? $0 : nil }
                    case "episode": metadata?.episode = Int(value).flatMap { (0...999).contains($0) ? $0 : nil }
                    case "set": if metadata?.collection == nil { metadata?.collection = String(value.prefix(200)) }
                    default: break
                    }
                } else if stack.count == 3, stack[1] == "set", name == "name" {
                    metadata?.collection = String(value.prefix(200))
                }
            }
            stack.removeLast(); contents.removeLast(); attributes.removeLast()
        }

        private func positive(_ value: String) -> Int? { Int(value).flatMap { $0 > 0 ? $0 : nil } }
        private func certification(_ value: String) -> String? {
            let ratings = ["G", "PG", "PG-13", "R", "NC-17", "TV-Y", "TV-Y7", "TV-Y7-FV", "TV-G", "TV-PG", "TV-14", "TV-MA"]
            let normalized = value.uppercased().replacingOccurrences(of: "RATED ", with: "")
            if ratings.contains(normalized) { return normalized }
            if normalized.hasPrefix("US:"), ratings.contains(String(normalized.dropFirst(3)).trimmingCharacters(in: .whitespaces)) {
                return String(normalized.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { invalid = true; parser.abortParsing(); return nil }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true; parser.abortParsing() }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
    }
}

public enum LocalMediaSidecars {
    public static func baseName(_ path: String) -> String { (path as NSString).deletingPathExtension }
    public static func metadataCandidates(video: String, singleVideo: Bool) -> [String] {
        let directory = (video as NSString).deletingLastPathComponent
        let specific = [baseName(video) + ".nfo", baseName(video) + ".xml"]
        return specific + (singleVideo ? [join(directory, "movie.nfo"), join(directory, "movie.xml")] : [])
    }
    public static func artworkCandidates(video: String, backdrop: Bool, singleVideo: Bool) -> [String] {
        let base = baseName(video)
        let names = backdrop ? [base + "-fanart"] : [base + "-poster", base]
        let directory = (video as NSString).deletingLastPathComponent
        let common = singleVideo ? (backdrop ? [join(directory, "fanart"), join(directory, "backdrop")] : [join(directory, "poster"), join(directory, "folder")]) : []
        return (names + common).flatMap { name in ["jpg", "png", "jpeg", "webp"].map { name + "." + $0 } }
    }
    public static func join(_ directory: String, _ name: String) -> String { directory.isEmpty ? name : directory + "/" + name }
}
