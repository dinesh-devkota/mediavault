import Foundation

public struct SubtitleCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
}

public enum SubtitleError: Error, Equatable {
    case tooLarge, invalidEncoding, noCues
}

/// Plain text captions only. Styling, script, remote references and positioning are never executed.
public struct SubtitleDocument: Sendable {
    public static let maximumBytes = 2 * 1024 * 1024
    public static let maximumCues = 20_000
    public let cues: [SubtitleCue]
    private let prefixEnd: [Double]

    public static func parse(_ data: Data) throws -> SubtitleDocument {
        guard data.count <= maximumBytes else { throw SubtitleError.tooLarge }
        let decoded: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            decoded = String(data: data, encoding: .utf16)
        } else { decoded = String(data: data, encoding: .utf8) }
        guard let decoded else { throw SubtitleError.invalidEncoding }
        let normalized = decoded.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [[String]] = [], block: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !block.isEmpty { blocks.append(block); block = [] }
            } else { block.append(line) }
        }
        if !block.isEmpty { blocks.append(block) }
        var cues: [SubtitleCue] = []
        for lines in blocks {
            guard let first = lines.first else { continue }
            if first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t")
                || first == "STYLE" || first == "REGION" || first.hasPrefix("WEBVTT") { continue }
            guard let index = lines.prefix(2).firstIndex(where: { $0.contains("-->") }), index + 1 < lines.count else { continue }
            let times = lines[index].components(separatedBy: "-->")
            guard times.count == 2, let start = timestamp(times[0]),
                  let endToken = times[1].split(whereSeparator: \.isWhitespace).first,
                  let end = timestamp(String(endToken)), end > start else { continue }
            let text = plainText(lines.dropFirst(index + 1).joined(separator: "\n"))
            guard !text.isEmpty, text.count <= 4096 else { continue }
            guard cues.count < maximumCues else { throw SubtitleError.tooLarge }
            cues.append(SubtitleCue(start: start, end: end, text: text))
        }
        guard !cues.isEmpty else { throw SubtitleError.noCues }
        cues.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var maximum = 0.0
        let prefix = cues.map { cue -> Double in maximum = max(maximum, cue.end); return maximum }
        return SubtitleDocument(cues: cues, prefixEnd: prefix)
    }

    /// Binary search handles seeking in either direction. End times are exclusive.
    public func text(at seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= seconds { low = mid + 1 } else { high = mid }
        }
        var index = low - 1, active: [String] = []
        while index >= 0, prefixEnd[index] > seconds {
            if cues[index].end > seconds { active.append(cues[index].text) }
            if active.count == 4 { break }
            index -= 1
        }
        return active.reversed().joined(separator: "\n")
    }

    private static func timestamp(_ value: String) -> Double? {
        let value = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsParts = parts.last!.split(separator: ".", omittingEmptySubsequences: false)
        guard secondsParts.count == 2, secondsParts[0].count == 2, secondsParts[1].count == 3,
              secondsParts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let seconds = Double(parts.last!), seconds < 60,
              parts.dropLast().allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let minutes = Double(parts[parts.count - 2]), minutes < 60 else { return nil }
        let hours = parts.count == 3 ? Double(parts[0]) ?? 0 : 0
        let total = hours * 3600 + minutes * 60 + seconds
        return total.isFinite && total <= 7 * 24 * 3600 ? total : nil
    }

    private static func plainText(_ value: String) -> String {
        var text = value.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
        for (entity, replacement) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value == 10 || $0.value == 9 || $0.value >= 32 && !(127...159).contains($0.value) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SubtitleFile: Identifiable, Equatable, Sendable {
    public let path: String
    public let language: String?
    public let forced: Bool
    public let hearingImpaired: Bool
    public init(path: String, language: String?, forced: Bool = false, hearingImpaired: Bool = false) {
        self.path = path
        self.language = language
        self.forced = forced
        self.hearingImpaired = hearingImpaired
    }

    public var id: String { path }
    public var preference: String { ["local", language ?? "und", forced ? "forced" : "", hearingImpaired ? "sdh" : ""].joined(separator: "|") }
    public var label: String {
        let name = language.flatMap { Locale.current.localizedString(forIdentifier: $0) } ?? language ?? "Local subtitles"
        return ([name] + (forced ? ["Forced"] : []) + (hearingImpaired ? ["SDH"] : [])).joined(separator: " · ")
    }

    /// Source and file paths are share-relative; reject traversal rather than standardizing it away.
    public static func safePath(_ path: String, within root: String, allowRoot: Bool = false, caseSensitive: Bool = false) -> String? {
        func parts(_ path: String) -> [String]? {
            let slashed = path.replacingOccurrences(of: "\\", with: "/")
            guard !slashed.hasPrefix("//"), !slashed.contains(":"),
                  !slashed.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { return nil }
            let values = slashed.split(separator: "/").map(String.init)
            guard !values.contains("."), !values.contains("..") else { return nil }
            return values
        }
        guard let path = parts(path), let root = parts(root), path.count >= root.count,
              zip(root, path).allSatisfy({ left, right in
                  caseSensitive ? left.utf8.elementsEqual(right.utf8) : left.lowercased() == right.lowercased()
              }),
              allowRoot || path.count > root.count else { return nil }
        return path.joined(separator: "/")
    }

    public static func directory(for videoPath: String, rootPath: String, caseSensitive: Bool = false) -> String? {
        guard let path = safePath(videoPath, within: rootPath, caseSensitive: caseSensitive) else { return nil }
        return path.split(separator: "/").dropLast().joined(separator: "/")
    }

    public static func match(name: String, videoPath: String, rootPath: String,
                             ignoredFolders: [String] = [], ignoredFiles: [String] = [], caseSensitive: Bool = false) -> SubtitleFile? {
        guard !name.contains("/"), !name.contains("\\"),
              let directory = directory(for: videoPath, rootPath: rootPath, caseSensitive: caseSensitive),
              !ScanExclusions.isFileExcluded(path: videoPath, rootPath: rootPath, ignoredFolders: ignoredFolders, ignoredFiles: ignoredFiles, caseSensitive: caseSensitive) else { return nil }
        let path = directory.isEmpty ? name : directory + "/" + name
        guard let safe = safePath(path, within: rootPath, caseSensitive: caseSensitive),
              !ScanExclusions.isFileExcluded(path: safe, rootPath: rootPath, ignoredFolders: ignoredFolders, ignoredFiles: ignoredFiles, caseSensitive: caseSensitive) else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        guard ext == "srt" || ext == "vtt" else { return nil }
        let videoStem = ((videoPath.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent as NSString).deletingPathExtension
        let subtitleStem = (name as NSString).deletingPathExtension
        let base = caseSensitive ? videoStem : videoStem.lowercased()
        let subtitleBase = caseSensitive ? subtitleStem : subtitleStem.lowercased()
        let exact = caseSensitive ? subtitleBase.utf8.elementsEqual(base.utf8) : subtitleBase == base
        let prefix = caseSensitive ? subtitleBase.utf8.starts(with: (base + ".").utf8) : subtitleBase.hasPrefix(base + ".")
        guard exact || prefix else { return nil }
        let suffix = exact ? "" : String(subtitleBase.dropFirst(base.count + 1)).lowercased()
        guard exact || !suffix.isEmpty else { return nil }
        let tokens = suffix.isEmpty ? [] : suffix.components(separatedBy: ".")
        var language: String?, forced = false, sdh = false
        for token in tokens {
            if token == "forced", !forced { forced = true }
            else if (token == "sdh" || token == "cc"), !sdh { sdh = true }
            else if !["forced", "sdh", "cc"].contains(token), language == nil,
                    token.range(of: #"^[a-z]{2,3}(-[a-z0-9]{2,8}){0,2}$"#, options: .regularExpression) != nil { language = token }
            else { return nil }
        }
        return SubtitleFile(path: safe, language: language, forced: forced, hearingImpaired: sdh)
    }
}
