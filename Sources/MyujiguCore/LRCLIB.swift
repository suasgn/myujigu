import Foundation

public enum LRCLIBError: LocalizedError, Sendable {
    case request(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case let .request(status):
            return "LRCLIB lyrics request failed (HTTP \(status))."
        case .malformedResponse:
            return "LRCLIB returned an unreadable lyrics response."
        }
    }
}

public enum LRCParser {
    private struct PendingLine {
        let startTimeMs: Int
        let order: Int
        let words: String
    }

    public static func parse(_ value: String, durationMs: Int = 0) -> Lyrics? {
        let timestampPattern = #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
        guard let timestampExpression = try? NSRegularExpression(pattern: timestampPattern) else {
            return nil
        }
        let offsetExpression = try? NSRegularExpression(
            pattern: #"(?im)^\[offset:([+-]?\d+)\]\s*$"#
        )
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let offsetMs = offsetExpression?
            .firstMatch(in: value, range: fullRange)
            .flatMap { match -> Int? in
                guard let range = Range(match.range(at: 1), in: value) else { return nil }
                return Int(value[range])
            } ?? 0

        var pending: [PendingLine] = []
        var order = 0
        for rawLine in value.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = timestampExpression.matches(in: rawLine, range: range)
            guard !matches.isEmpty else { continue }

            let words = timestampExpression
                .stringByReplacingMatches(in: rawLine, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { continue }

            for match in matches {
                guard let minutesRange = Range(match.range(at: 1), in: rawLine),
                      let secondsRange = Range(match.range(at: 2), in: rawLine),
                      let minutes = Int(rawLine[minutesRange]),
                      let seconds = Int(rawLine[secondsRange]),
                      seconds < 60
                else {
                    continue
                }
                let fraction: Int
                if let fractionRange = Range(match.range(at: 3), in: rawLine) {
                    let digits = rawLine[fractionRange]
                    guard let rawFraction = Int(digits) else { continue }
                    switch digits.count {
                    case 1: fraction = rawFraction * 100
                    case 2: fraction = rawFraction * 10
                    default: fraction = rawFraction
                    }
                } else {
                    fraction = 0
                }
                let timestamp = max((minutes * 60 + seconds) * 1_000 + fraction + offsetMs, 0)
                pending.append(PendingLine(startTimeMs: timestamp, order: order, words: words))
                order += 1
            }
        }

        pending.sort {
            $0.startTimeMs == $1.startTimeMs
                ? $0.order < $1.order
                : $0.startTimeMs < $1.startTimeMs
        }
        guard !pending.isEmpty else { return nil }

        var unique: [PendingLine] = []
        for line in pending {
            if unique.last?.startTimeMs == line.startTimeMs {
                unique[unique.count - 1] = line
            } else {
                unique.append(line)
            }
        }
        let lines = unique.enumerated().map { index, line in
            let nextStart = index + 1 < unique.count ? unique[index + 1].startTimeMs : nil
            let fallbackEnd = durationMs > line.startTimeMs
                ? durationMs
                : line.startTimeMs + 10_000
            return LyricLine(
                startTimeMs: line.startTimeMs,
                endTimeMs: max(nextStart ?? fallbackEnd, line.startTimeMs + 1),
                words: line.words
            )
        }
        return Lyrics(syncType: "LINE_SYNCED", lines: lines, provider: "LRCLIB")
    }

    public static func parsePlain(_ value: String, durationMs: Int = 0) -> Lyrics? {
        let words = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        return Lyrics(
            syncType: "UNSYNCED",
            lines: [
                LyricLine(
                    startTimeMs: 0,
                    endTimeMs: max(durationMs, 10_000),
                    words: words
                ),
            ],
            provider: "LRCLIB"
        )
    }
}

public actor LRCLIBClient {
    private struct Response: Codable {
        let id: Int?
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private struct CachedResult: Codable {
        let fetchedAt: Date
        let lyrics: Lyrics?
    }

    private struct VerifiedCandidate {
        let lyrics: Lyrics
        let textScore: Double
        let durationDifferenceMs: Int
    }

    private let baseURL: URL
    private let session: URLSession
    private let cacheDirectory: URL
    private let positiveCacheLifetime: TimeInterval = 30 * 24 * 60 * 60
    private let negativeCacheLifetime: TimeInterval = 30 * 60

    public init(
        baseURL: URL = URL(string: "https://lrclib.net")!,
        session: URLSession = .shared,
        cacheDirectory: URL? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.cacheDirectory = cacheDirectory
            ?? applicationSupport
                .appendingPathComponent("Myujigu", isDirectory: true)
                .appendingPathComponent("Cache", isDirectory: true)
                .appendingPathComponent("LRCLIB", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    public func fetchLyrics(
        title: String,
        artist: String,
        album: String = "",
        durationMs: Int = 0,
        ignoreCache: Bool = false
    ) async throws -> Lyrics? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        let cacheKey = Self.cacheKey(
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs
        )
        if !ignoreCache, let cached = readCache(cacheKey) {
            let lifetime = cached.lyrics == nil ? negativeCacheLifetime : positiveCacheLifetime
            if Date().timeIntervalSince(cached.fetchedAt) < lifetime {
                return cached.lyrics
            }
        }

        let exactResponse = try await exactMatch(
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs
        )
        var selected = exactResponse
        let hasExactSyncedLyrics = exactResponse?.syncedLyrics?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        if !hasExactSyncedLyrics {
            selected = try await searchMatch(
                title: title,
                artist: artist,
                album: album,
                durationMs: durationMs
            ) ?? exactResponse
        }

        let lyrics = selected.flatMap { response in
            makeLyrics(from: response, requestedDurationMs: durationMs)
        }
        writeCache(CachedResult(fetchedAt: Date(), lyrics: lyrics), key: cacheKey)
        return lyrics
    }

    /// Finds synchronized lyrics for a native player only when LRCLIB's record
    /// can be tied to the current track conservatively. Unlike `fetchLyrics`,
    /// this requires album and duration metadata and never returns plain lyrics.
    /// When native plain lyrics are available, their text must also agree with
    /// the synchronized LRCLIB text.
    public func fetchVerifiedSyncedLyrics(
        title: String,
        artist: String,
        album: String,
        durationMs: Int,
        matching referenceLyrics: Lyrics? = nil,
        ignoreCache: Bool = false
    ) async throws -> Lyrics? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty, !album.isEmpty, durationMs > 0 else {
            return nil
        }

        let referenceText = referenceLyrics
            .map { $0.lines.map(\.words).joined(separator: "\n") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let referenceFingerprint = referenceText
            .map { normalizedTokens($0).joined(separator: " ") }
            ?? "metadata-only"
        let cacheKey = Self.cacheKey(
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs,
            variant: "verified-synced-v1:\(referenceFingerprint)"
        )
        if !ignoreCache, let cached = readCache(cacheKey) {
            let lifetime = cached.lyrics == nil ? negativeCacheLifetime : positiveCacheLifetime
            if Date().timeIntervalSince(cached.fetchedAt) < lifetime {
                return cached.lyrics
            }
        }

        let exact = try await exactResponse(
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs
        )
        if let exact,
           let verified = verifiedCandidate(
               exact,
               title: title,
               artist: artist,
               album: album,
               durationMs: durationMs,
               referenceText: referenceText
           )
        {
            writeCache(CachedResult(fetchedAt: Date(), lyrics: verified.lyrics), key: cacheKey)
            return verified.lyrics
        }

        let responses = try await searchResponses(
            title: title,
            artist: artist,
            album: album
        )
        let verified = selectVerifiedCandidate(
            responses,
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs,
            referenceText: referenceText
        )?.lyrics
        writeCache(CachedResult(fetchedAt: Date(), lyrics: verified), key: cacheKey)
        return verified
    }

    private func exactMatch(
        title: String,
        artist: String,
        album: String,
        durationMs: Int
    ) async throws -> Response? {
        guard let response = try await exactResponse(
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs
        ) else {
            return nil
        }
        return metadataMatches(
            response,
            title: title,
            artist: artist,
            durationMs: durationMs
        ) ? response : nil
    }

    private func exactResponse(
        title: String,
        artist: String,
        album: String,
        durationMs: Int
    ) async throws -> Response? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/get"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = metadataQueryItems(
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs
        )
        let (data, status) = try await request(components.url!)
        if status == 404 { return nil }
        guard status == 200 else { throw LRCLIBError.request(status) }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw LRCLIBError.malformedResponse
        }
        return response
    }

    private func searchMatch(
        title: String,
        artist: String,
        album: String,
        durationMs: Int
    ) async throws -> Response? {
        let responses = try await searchResponses(
            title: title,
            artist: artist,
            album: album
        )
        return responses
            .filter {
                metadataMatches(
                    $0,
                    title: title,
                    artist: artist,
                    durationMs: durationMs
                ) && $0.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            .max { left, right in
                matchScore(left, album: album, durationMs: durationMs)
                    < matchScore(right, album: album, durationMs: durationMs)
            }
    }

    private func searchResponses(
        title: String,
        artist: String,
        album: String
    ) async throws -> [Response] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/search"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if !album.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "album_name", value: album))
        }
        let (data, status) = try await request(components.url!)
        guard status == 200 else { throw LRCLIBError.request(status) }
        guard let responses = try? JSONDecoder().decode([Response].self, from: data) else {
            throw LRCLIBError.malformedResponse
        }
        return responses
    }

    private func metadataQueryItems(
        title: String,
        artist: String,
        album: String,
        durationMs: Int
    ) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if durationMs > 0 {
            let seconds = String(
                format: "%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                Double(durationMs) / 1_000
            )
            items.append(URLQueryItem(name: "duration", value: seconds))
        }
        return items
    }

    private func request(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Myujigu/1.0 (macOS menu-bar lyrics)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw LRCLIBError.malformedResponse
        }
        return (data, response.statusCode)
    }

    private func metadataMatches(
        _ response: Response,
        title: String,
        artist: String,
        durationMs: Int
    ) -> Bool {
        guard normalize(response.trackName ?? "") == normalize(title),
              normalize(response.artistName ?? "") == normalize(artist)
        else {
            return false
        }
        if durationMs > 0, let responseDuration = response.duration,
           abs(Int((responseDuration * 1_000).rounded()) - durationMs) > 5_000
        {
            return false
        }
        return true
    }

    private func matchScore(_ response: Response, album: String, durationMs: Int) -> Int {
        var score = 0
        if !album.isEmpty, normalize(response.albumName ?? "") == normalize(album) {
            score += 20
        }
        if durationMs > 0, let duration = response.duration {
            let difference = abs(Int((duration * 1_000).rounded()) - durationMs)
            score += max(0, 20 - difference / 250)
        }
        return score
    }

    private func makeLyrics(from response: Response, requestedDurationMs: Int) -> Lyrics? {
        let responseDurationMs = response.duration.map { Int(($0 * 1_000).rounded()) } ?? 0
        let durationMs = requestedDurationMs > 0 ? requestedDurationMs : responseDurationMs
        if let synced = response.syncedLyrics,
           let lyrics = LRCParser.parse(synced, durationMs: durationMs)
        {
            return lyrics
        }
        if let plain = response.plainLyrics {
            return LRCParser.parsePlain(plain, durationMs: durationMs)
        }
        return nil
    }

    private func makeSynchronizedLyrics(
        from response: Response,
        requestedDurationMs: Int
    ) -> Lyrics? {
        guard let synced = response.syncedLyrics else { return nil }
        return LRCParser.parse(synced, durationMs: requestedDurationMs)
    }

    private func verifiedCandidate(
        _ response: Response,
        title: String,
        artist: String,
        album: String,
        durationMs: Int,
        referenceText: String?
    ) -> VerifiedCandidate? {
        guard strictNormalize(response.trackName ?? "") == strictNormalize(title),
              strictNormalize(response.artistName ?? "") == strictNormalize(artist),
              strictNormalize(response.albumName ?? "") == strictNormalize(album),
              let responseDuration = response.duration
        else {
            return nil
        }

        let responseDurationMs = Int((responseDuration * 1_000).rounded())
        let durationDifferenceMs = abs(responseDurationMs - durationMs)
        guard durationDifferenceMs <= 2_000,
              let lyrics = makeSynchronizedLyrics(
                  from: response,
                  requestedDurationMs: durationMs
              )
        else {
            return nil
        }

        let textScore: Double
        if let referenceText {
            let candidateText = lyrics.lines.map(\.words).joined(separator: "\n")
            guard let similarity = lyricTextSimilarity(
                reference: referenceText,
                candidate: candidateText
            ) else {
                return nil
            }
            textScore = similarity
        } else {
            textScore = 1
        }

        return VerifiedCandidate(
            lyrics: lyrics,
            textScore: textScore,
            durationDifferenceMs: durationDifferenceMs
        )
    }

    private func selectVerifiedCandidate(
        _ responses: [Response],
        title: String,
        artist: String,
        album: String,
        durationMs: Int,
        referenceText: String?
    ) -> VerifiedCandidate? {
        let candidates = responses.compactMap {
            verifiedCandidate(
                $0,
                title: title,
                artist: artist,
                album: album,
                durationMs: durationMs,
                referenceText: referenceText
            )
        }.sorted {
            if $0.textScore != $1.textScore {
                return $0.textScore > $1.textScore
            }
            return $0.durationDifferenceMs < $1.durationDifferenceMs
        }

        guard let best = candidates.first else { return nil }
        if candidates.count > 1 {
            let runnerUp = candidates[1]
            let sameLyrics = best.lyrics.lines == runnerUp.lyrics.lines
            let clearlyBetterText = best.textScore - runnerUp.textScore >= 0.03
            let clearlyCloserDuration = runnerUp.durationDifferenceMs
                - best.durationDifferenceMs >= 500
            if !sameLyrics, !clearlyBetterText, !clearlyCloserDuration {
                return nil
            }
        }
        return best
    }

    private func lyricTextSimilarity(reference: String, candidate: String) -> Double? {
        let referenceTokens = normalizedTokens(reference)
        let candidateTokens = normalizedTokens(candidate)
        guard !referenceTokens.isEmpty, !candidateTokens.isEmpty else { return nil }

        if max(referenceTokens.count, candidateTokens.count) <= 8 {
            return referenceTokens == candidateTokens ? 1 : nil
        }
        guard referenceTokens.count <= 4_000, candidateTokens.count <= 4_000 else {
            return nil
        }

        var previous = [Int](repeating: 0, count: candidateTokens.count + 1)
        for referenceToken in referenceTokens {
            var current = [Int](repeating: 0, count: candidateTokens.count + 1)
            for candidateIndex in candidateTokens.indices {
                if referenceToken == candidateTokens[candidateIndex] {
                    current[candidateIndex + 1] = previous[candidateIndex] + 1
                } else {
                    current[candidateIndex + 1] = max(
                        previous[candidateIndex + 1],
                        current[candidateIndex]
                    )
                }
            }
            previous = current
        }

        let commonTokenCount = previous[candidateTokens.count]
        let shorterCount = min(referenceTokens.count, candidateTokens.count)
        let longerCount = max(referenceTokens.count, candidateTokens.count)
        let shorterCoverage = Double(commonTokenCount) / Double(shorterCount)
        let longerCoverage = Double(commonTokenCount) / Double(longerCount)
        guard shorterCoverage >= 0.90, longerCoverage >= 0.82 else { return nil }
        return shorterCoverage * 0.6 + longerCoverage * 0.4
    }

    private func normalizedTokens(_ value: String) -> [String] {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        var tokens: [String] = []
        var token = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                token.unicodeScalars.append(scalar)
            } else if scalar.value == 0x27 || scalar.value == 0x2019 {
                continue
            } else if !token.isEmpty {
                tokens.append(token)
                token = ""
            }
        }
        if !token.isEmpty {
            tokens.append(token)
        }
        return tokens
    }

    private func strictNormalize(_ value: String) -> String {
        normalizedTokens(value).joined(separator: " ")
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private func readCache(_ key: String) -> CachedResult? {
        let url = cacheDirectory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedResult.self, from: data)
    }

    private func writeCache(_ result: CachedResult, key: String) {
        let url = cacheDirectory.appendingPathComponent("\(key).json")
        guard let data = try? JSONEncoder().encode(result) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func cacheKey(
        title: String,
        artist: String,
        album: String,
        durationMs: Int,
        variant: String = ""
    ) -> String {
        let metadata = "\(title)\u{1f}\(artist)\u{1f}\(album)\u{1f}\(durationMs)"
        let value = (variant.isEmpty ? metadata : "\(variant)\u{1f}\(metadata)")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
