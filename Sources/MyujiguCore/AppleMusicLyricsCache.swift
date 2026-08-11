import Foundation

struct AppleMusicLyricsDocument: Sendable {
    let title: String
    let durationMs: Int
    let lyrics: Lyrics
}

public enum AppleMusicLyricsParser {
    public static func parse(_ data: Data) -> Lyrics? {
        parseDocument(data)?.lyrics
    }

    static func parseDocument(_ data: Data) -> AppleMusicLyricsDocument? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let ttml = object["ttml"] as? String,
            let xmlData = ttml.data(using: .utf8)
        else {
            return nil
        }

        let delegate = TTMLDelegate()
        let parser = XMLParser(data: xmlData)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse(), !delegate.lines.isEmpty else { return nil }

        let lines = delegate.lines.enumerated().map { index, line in
            let nextStart = index + 1 < delegate.lines.count
                ? delegate.lines[index + 1].startTimeMs
                : nil
            let fallbackEnd = nextStart
                ?? (delegate.durationMs > line.startTimeMs ? delegate.durationMs : nil)
                ?? (line.startTimeMs + 10_000)
            return LyricLine(
                startTimeMs: line.startTimeMs,
                endTimeMs: max(line.endTimeMs ?? fallbackEnd, line.startTimeMs + 1),
                words: line.words
            )
        }

        return AppleMusicLyricsDocument(
            title: delegate.title,
            durationMs: delegate.durationMs,
            lyrics: Lyrics(
                syncType: "LINE_SYNCED",
                lines: lines,
                provider: "Apple Music",
                language: delegate.language
            )
        )
    }

    static func timeMilliseconds(_ value: String) -> Int? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("s"), let seconds = Double(value.dropLast()) {
            return Int((seconds * 1_000).rounded())
        }

        // Apple uses bare decimal seconds for timestamps below one minute
        // (for example `7.165`), then switches to clock time (`1:04.465`).
        if let seconds = Double(value) {
            return Int((seconds * 1_000).rounded())
        }

        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        let minutesIndex = parts.count == 3 ? 1 : 0
        guard let hours,
              let minutes = Double(parts[minutesIndex]),
              let seconds = Double(parts[minutesIndex + 1])
        else {
            return nil
        }
        return Int(((hours * 3_600 + minutes * 60 + seconds) * 1_000).rounded())
    }

    private final class TTMLDelegate: NSObject, XMLParserDelegate {
        struct ParsedLine {
            let startTimeMs: Int
            let endTimeMs: Int?
            let words: String
        }

        private struct PendingLine {
            let startTimeMs: Int
            let endTimeMs: Int?
            var words = ""
        }

        private(set) var title = ""
        private(set) var language: String?
        private(set) var durationMs = 0
        private(set) var lines: [ParsedLine] = []
        private var pendingLine: PendingLine?
        private var isReadingTitle = false
        private var pendingTitle = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "tt":
                language = attribute(named: "lang", in: attributeDict)
            case "body":
                durationMs = attribute(named: "dur", in: attributeDict)
                    .flatMap(AppleMusicLyricsParser.timeMilliseconds) ?? 0
            case "title" where pendingLine == nil:
                isReadingTitle = true
                pendingTitle = ""
            case "p":
                guard let begin = attribute(named: "begin", in: attributeDict)
                    .flatMap(AppleMusicLyricsParser.timeMilliseconds)
                else {
                    return
                }
                let end = attribute(named: "end", in: attributeDict)
                    .flatMap(AppleMusicLyricsParser.timeMilliseconds)
                pendingLine = PendingLine(startTimeMs: begin, endTimeMs: end)
            case "br":
                pendingLine?.words.append("\n")
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if pendingLine != nil {
                pendingLine?.words.append(string)
            } else if isReadingTitle {
                pendingTitle.append(string)
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if elementName == "title", isReadingTitle {
                title = normalizedWhitespace(pendingTitle)
                isReadingTitle = false
                return
            }

            guard elementName == "p", let line = pendingLine else { return }
            pendingLine = nil
            let words = normalizedWhitespace(line.words)
            guard !words.isEmpty else { return }
            lines.append(
                ParsedLine(
                    startTimeMs: line.startTimeMs,
                    endTimeMs: line.endTimeMs,
                    words: words
                )
            )
        }

        private func attribute(named name: String, in attributes: [String: String]) -> String? {
            attributes.first {
                $0.key == name || $0.key.hasSuffix(":\(name)")
            }?.value
        }

        private func normalizedWhitespace(_ value: String) -> String {
            value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
    }
}

public actor AppleMusicLyricsCache {
    private static let rowSeparator = Character(UnicodeScalar(31))

    private let cacheDirectory: URL

    public init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/com.apple.Music", isDirectory: true)
    }

    public func findLyrics(
        title: String,
        durationMs: Int,
        plainLyrics: String? = nil
    ) -> Lyrics? {
        let normalizedTitle = normalize(title)
        guard !normalizedTitle.isEmpty else { return nil }
        let normalizedPlainLyrics = plainLyrics.map(normalize) ?? ""
        var durationFallback: Lyrics?

        for data in cachedTTMLResponses() {
            guard let document = AppleMusicLyricsParser.parseDocument(data) else { continue }
            if durationMs > 0,
               document.durationMs > 0,
               !timelinesCanMatch(
                   trackDurationMs: durationMs,
                   lyricDurationMs: document.durationMs
               )
            {
                continue
            }

            if !document.title.isEmpty, normalize(document.title) == normalizedTitle {
                return document.lyrics
            }

            if !normalizedPlainLyrics.isEmpty {
                let timedLyrics = normalize(
                    document.lyrics.lines.map(\.words).joined(separator: " ")
                )
                if lyricBodiesMatch(normalizedPlainLyrics, timedLyrics) {
                    return document.lyrics
                }
            }

            // Apple's current TTML response omits title and artist metadata.
            // Keep the newest plausible-duration result as a final fallback;
            // cache rows are already ordered newest first. TTML often ends at
            // the final lyric, several seconds before the audio itself ends.
            if durationFallback == nil,
               durationMs > 0,
               document.durationMs > 0,
               timelinesCanMatch(
                   trackDurationMs: durationMs,
                   lyricDurationMs: document.durationMs
               )
            {
                durationFallback = document.lyrics
            }
        }
        return durationFallback
    }

    private func cachedTTMLResponses() -> [Data] {
        let database = cacheDirectory.appendingPathComponent("Cache.db")
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }

        let query = """
        SELECT r.isDataOnFS, hex(r.receiver_data)
        FROM cfurl_cache_response AS c
        JOIN cfurl_cache_receiver_data AS r USING(entry_ID)
        WHERE instr(lower(c.request_key), '/ttmllyrics?') > 0
        ORDER BY c.entry_ID DESC
        LIMIT 50;
        """
        guard let output = runSQLite(database: database, query: query) else { return [] }

        return output.split(whereSeparator: { $0.isNewline }).compactMap { row in
            let fields = row.split(
                separator: Self.rowSeparator,
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard fields.count == 2,
                  let receiverData = dataFromHex(String(fields[1]))
            else {
                return nil
            }

            if fields[0] == "1",
               let fileName = String(data: receiverData, encoding: .utf8)
            {
                let payload = cacheDirectory
                    .appendingPathComponent("fsCachedData", isDirectory: true)
                    .appendingPathComponent(fileName)
                return try? Data(contentsOf: payload, options: [.mappedIfSafe])
            }
            return receiverData
        }
    }

    private func runSQLite(database: URL, query: String) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            "-separator", String(Self.rowSeparator),
            database.path,
            query,
        ]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func dataFromHex(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private func lyricBodiesMatch(_ first: String, _ second: String) -> Bool {
        guard !first.isEmpty, !second.isEmpty else { return false }
        let comparisonLength = min(first.count, second.count, 180)
        guard comparisonLength >= 24 else { return first == second }
        return first.prefix(comparisonLength) == second.prefix(comparisonLength)
    }

    private func timelinesCanMatch(trackDurationMs: Int, lyricDurationMs: Int) -> Bool {
        let difference = trackDurationMs - lyricDurationMs
        if difference >= 0 {
            let trailingAudioAllowance = max(
                15_000,
                Int((Double(trackDurationMs) * 0.04).rounded())
            )
            return difference <= trailingAudioAllowance
        }

        // Permit small rounding or metadata differences, but not a lyric
        // timeline that materially outlasts the current track.
        return -difference <= 3_000
    }
}
