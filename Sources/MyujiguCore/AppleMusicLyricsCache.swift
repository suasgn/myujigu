import Foundation

struct AppleMusicLyricsDocument: Sendable {
    let title: String
    let artists: [String]
    let songwriters: [String]
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
            artists: delegate.artists,
            songwriters: delegate.songwriters,
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
        private(set) var artists: [String] = []
        private(set) var songwriters: [String] = []
        private(set) var language: String?
        private(set) var durationMs = 0
        private(set) var lines: [ParsedLine] = []
        private var pendingLine: PendingLine?
        private var isReadingTitle = false
        private var pendingTitle = ""
        private var isInsideAgent = false
        private var isReadingArtist = false
        private var pendingArtist = ""
        private var isReadingSongwriter = false
        private var pendingSongwriter = ""

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
            case "agent":
                isInsideAgent = true
            case "name" where isInsideAgent:
                isReadingArtist = true
                pendingArtist = ""
            case "songwriter":
                isReadingSongwriter = true
                pendingSongwriter = ""
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
            } else if isReadingArtist {
                pendingArtist.append(string)
            } else if isReadingSongwriter {
                pendingSongwriter.append(string)
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

            if elementName == "name", isReadingArtist {
                let artist = normalizedWhitespace(pendingArtist)
                if !artist.isEmpty, !artists.contains(artist) {
                    artists.append(artist)
                }
                isReadingArtist = false
                return
            }

            if elementName == "agent" {
                isInsideAgent = false
                return
            }

            if elementName == "songwriter", isReadingSongwriter {
                let songwriter = normalizedWhitespace(pendingSongwriter)
                if !songwriter.isEmpty, !songwriters.contains(songwriter) {
                    songwriters.append(songwriter)
                }
                isReadingSongwriter = false
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

    private struct CachedResponse {
        let requestKey: String
        let data: Data
    }

    private struct CatalogMetadata {
        let catalogID: String
        let title: String
        let artist: String
        let album: String
        let durationMs: Int?
    }

    private struct LyricsCandidate {
        let catalogID: String?
        let document: AppleMusicLyricsDocument
    }

    private let cacheDirectory: URL

    public init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/com.apple.Music", isDirectory: true)
    }

    public func findLyrics(
        title: String,
        durationMs: Int,
        artist: String = "",
        album: String = "",
        plainLyrics: String? = nil,
        catalogID: String? = nil
    ) -> Lyrics? {
        let normalizedTitle = normalize(title)
        guard !normalizedTitle.isEmpty else { return nil }
        let normalizedPlainLyrics = plainLyrics.map(normalize) ?? ""
        var candidates: [LyricsCandidate] = []

        for response in cachedTTMLResponses() {
            guard let document = AppleMusicLyricsParser.parseDocument(response.data) else {
                continue
            }
            if durationMs > 0,
               document.durationMs > durationMs + 3_000
            {
                continue
            }

            if let catalogID,
               self.catalogID(in: response.requestKey) == catalogID
            {
                return document.lyrics
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

            candidates.append(
                LyricsCandidate(
                    catalogID: self.catalogID(in: response.requestKey),
                    document: document
                )
            )
        }

        // Current Apple TTML omits the song title and artist. Its request URL
        // still contains the catalog song ID, and Music caches catalog metadata
        // for the same ID. Join those records so two similarly timed songs can
        // never be confused merely because their durations happen to match.
        let candidateIDs = Set(candidates.compactMap(\.catalogID))
        if !candidateIDs.isEmpty {
            let metadata = cachedCatalogMetadata(for: candidateIDs)
            if let matchedID = matchingCatalogID(
                in: metadata,
                title: title,
                artist: artist,
                album: album,
                durationMs: durationMs
            ) {
                return candidates.first { $0.catalogID == matchedID }?.document.lyrics
            }
        }

        // Music does not expose lyrics through AppleScript for many streaming
        // tracks, even while its Lyrics view is showing synchronized words.
        // Modern Apple TTML often includes its vocal agents. Some releases use
        // an empty agent but still list the performer among their songwriters,
        // so use either credit plus a close duration as a cache-only fallback.
        return matchingArtistLyrics(
            in: candidates,
            artist: artist,
            durationMs: durationMs
        )
    }

    private func cachedTTMLResponses() -> [CachedResponse] {
        cachedResponses(
            where: "instr(lower(c.request_key), '/ttmllyrics?') > 0",
            limit: 50
        )
    }

    private func cachedCatalogResponses() -> [CachedResponse] {
        cachedResponses(
            where: """
            instr(lower(c.request_key), '/lookup?') > 0
            OR instr(lower(c.request_key), '/v1/catalog/') > 0
            OR instr(lower(c.request_key), '/v1/editorial/') > 0
            """,
            limit: 50
        )
    }

    private func cachedResponses(where condition: String, limit: Int) -> [CachedResponse] {
        let database = cacheDirectory.appendingPathComponent("Cache.db")
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }

        let query = """
        SELECT c.request_key, r.isDataOnFS, hex(r.receiver_data)
        FROM cfurl_cache_response AS c
        JOIN cfurl_cache_receiver_data AS r USING(entry_ID)
        WHERE \(condition)
        ORDER BY c.entry_ID DESC
        LIMIT \(limit);
        """
        guard let output = runSQLite(database: database, query: query) else { return [] }

        return output.split(whereSeparator: { $0.isNewline }).compactMap { row in
            let fields = row.split(
                separator: Self.rowSeparator,
                maxSplits: 2,
                omittingEmptySubsequences: false
            )
            guard fields.count == 3,
                  let receiverData = dataFromHex(String(fields[2]))
            else {
                return nil
            }

            let data: Data?
            if fields[1] == "1",
               let fileName = String(data: receiverData, encoding: .utf8)
            {
                let payload = cacheDirectory
                    .appendingPathComponent("fsCachedData", isDirectory: true)
                    .appendingPathComponent(fileName)
                data = try? Data(contentsOf: payload, options: [.mappedIfSafe])
            } else {
                data = receiverData
            }
            guard let data else { return nil }
            return CachedResponse(requestKey: String(fields[0]), data: data)
        }
    }

    private func catalogID(in requestKey: String) -> String? {
        URLComponents(string: requestKey)?.queryItems?
            .first { $0.name == "id" }?
            .value
    }

    private func cachedCatalogMetadata(for candidateIDs: Set<String>) -> [CatalogMetadata] {
        var results: [CatalogMetadata] = []
        for response in cachedCatalogResponses() {
            guard let object = try? JSONSerialization.jsonObject(with: response.data) else {
                continue
            }
            collectCatalogMetadata(from: object, candidateIDs: candidateIDs, into: &results)
        }
        return results
    }

    private func collectCatalogMetadata(
        from object: Any,
        candidateIDs: Set<String>,
        into results: inout [CatalogMetadata]
    ) {
        if let dictionary = object as? [String: Any] {
            if let catalogID = stringValue(dictionary["id"]),
               candidateIDs.contains(catalogID),
               let metadata = catalogMetadata(catalogID: catalogID, in: dictionary)
            {
                results.append(metadata)
            }
            for value in dictionary.values {
                collectCatalogMetadata(from: value, candidateIDs: candidateIDs, into: &results)
            }
            return
        }

        if let array = object as? [Any] {
            for value in array {
                collectCatalogMetadata(from: value, candidateIDs: candidateIDs, into: &results)
            }
        }
    }

    private func catalogMetadata(
        catalogID: String,
        in dictionary: [String: Any]
    ) -> CatalogMetadata? {
        let attributes = dictionary["attributes"] as? [String: Any] ?? dictionary
        let title = stringValue(attributes["name"])
            ?? stringValue(attributes["trackName"])
            ?? ""
        let artist = stringValue(attributes["artistName"]) ?? ""
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        let album = stringValue(attributes["albumName"])
            ?? stringValue(attributes["collectionName"])
            ?? ""
        let durationMs = integerValue(attributes["durationInMillis"])
            ?? integerValue(attributes["trackTimeMillis"])
            ?? offerDurationMs(in: attributes)
        return CatalogMetadata(
            catalogID: catalogID,
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs
        )
    }

    private func offerDurationMs(in attributes: [String: Any]) -> Int? {
        guard let offers = attributes["offers"] as? [[String: Any]] else { return nil }
        for offer in offers {
            guard let assets = offer["assets"] as? [[String: Any]] else { continue }
            for asset in assets {
                if let seconds = doubleValue(asset["duration"]) {
                    return Int((seconds * 1_000).rounded())
                }
            }
        }
        return nil
    }

    private func matchingCatalogID(
        in metadata: [CatalogMetadata],
        title: String,
        artist: String,
        album: String,
        durationMs: Int
    ) -> String? {
        let normalizedTitle = normalize(title)
        let normalizedArtist = normalize(artist)
        let normalizedAlbum = normalize(album)

        let matches = metadata.filter { item in
            guard normalize(item.title) == normalizedTitle else { return false }
            if !normalizedArtist.isEmpty, normalize(item.artist) != normalizedArtist {
                return false
            }
            if !normalizedAlbum.isEmpty, normalize(item.album) != normalizedAlbum {
                return false
            }
            if durationMs > 0, let itemDurationMs = item.durationMs,
               abs(itemDurationMs - durationMs) > 3_000
            {
                return false
            }
            return true
        }
        guard !matches.isEmpty else { return nil }

        return matches.min { left, right in
            abs((left.durationMs ?? durationMs) - durationMs)
                < abs((right.durationMs ?? durationMs) - durationMs)
        }?.catalogID
    }

    private func matchingArtistLyrics(
        in candidates: [LyricsCandidate],
        artist: String,
        durationMs: Int
    ) -> Lyrics? {
        let normalizedArtist = normalize(artist)
        guard !normalizedArtist.isEmpty, durationMs > 0 else { return nil }

        let matches = candidates.filter { candidate in
            guard candidate.document.durationMs > 0,
                  abs(candidate.document.durationMs - durationMs) <= 15_000
            else {
                return false
            }
            let artistHints = candidate.document.artists + candidate.document.songwriters
            return artistHints.contains { artistHint in
                let normalizedHint = normalize(artistHint)
                guard normalizedHint.count >= 4 else { return false }
                return normalizedArtist == normalizedHint
                    || normalizedArtist.contains(normalizedHint)
                    || normalizedHint.contains(normalizedArtist)
            }
        }

        return matches.min { left, right in
            abs(left.document.durationMs - durationMs)
                < abs(right.document.durationMs - durationMs)
        }?.document.lyrics
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
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

}
