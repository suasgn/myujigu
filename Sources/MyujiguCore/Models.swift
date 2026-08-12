import Foundation

public struct Syllable: Codable, Equatable, Sendable {
    public let startTimeMs: Int
    public let count: Int

    public init(startTimeMs: Int, count: Int) {
        self.startTimeMs = startTimeMs
        self.count = count
    }
}

public struct LyricLine: Codable, Equatable, Sendable, Identifiable {
    public let startTimeMs: Int
    public let endTimeMs: Int
    public let words: String
    public let syllables: [Syllable]

    public var id: Int { startTimeMs }

    public init(startTimeMs: Int, endTimeMs: Int, words: String, syllables: [Syllable] = []) {
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.words = words
        self.syllables = syllables
    }
}

public struct Lyrics: Codable, Equatable, Sendable {
    public let syncType: String
    public let lines: [LyricLine]
    public let provider: String?
    public let language: String?

    public init(syncType: String, lines: [LyricLine], provider: String? = nil, language: String? = nil) {
        self.syncType = syncType
        self.lines = lines
        self.provider = provider
        self.language = language
    }

    public func activeLineIndex(at positionMs: Int) -> Int? {
        guard syncType.uppercased() != "UNSYNCED", !lines.isEmpty, positionMs >= lines[0].startTimeMs else {
            return nil
        }

        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].startTimeMs <= positionMs {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(0, low - 1)
    }
}

public enum PlayerStatus: String, Codable, Sendable {
    case playing
    case paused
    case stopped
    case unavailable
}

public enum PlayerKind: String, Codable, Sendable {
    case spotify
    case appleMusic
    case system
}

public struct PlayerState: Equatable, Sendable {
    public let status: PlayerStatus
    public let player: PlayerKind?
    public let trackID: String?
    public let positionMs: Int
    public let title: String
    public let artist: String
    public let album: String
    public let durationMs: Int
    public let artworkURL: URL?
    public let sourceName: String?
    public let bundleIdentifier: String?

    public static let stopped = PlayerState(
        status: .stopped,
        player: nil,
        trackID: nil,
        positionMs: 0,
        title: "",
        artist: "",
        album: "",
        durationMs: 0,
        artworkURL: nil,
        sourceName: nil,
        bundleIdentifier: nil
    )

    public init(
        status: PlayerStatus,
        player: PlayerKind? = nil,
        trackID: String?,
        positionMs: Int,
        title: String,
        artist: String,
        album: String = "",
        durationMs: Int = 0,
        artworkURL: URL? = nil,
        sourceName: String? = nil,
        bundleIdentifier: String? = nil
    ) {
        self.status = status
        self.player = player
        self.trackID = trackID
        self.positionMs = positionMs
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.artworkURL = artworkURL
        self.sourceName = sourceName
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum LyricsSource: String, Sendable {
    case spotifyCache = "Spotify cache"
    case spotifyAPI = "Spotify API"
    case appleMusicCache = "Apple Music cache"
    case lrclib = "LRCLIB"
}

public enum LyricsParser {
    public static func parse(_ data: Data) -> Lyrics? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = root["lyrics"] as? [String: Any],
            let rawLines = payload["lines"] as? [[String: Any]],
            !rawLines.isEmpty
        else {
            return nil
        }

        let starts = rawLines.map { integer($0["startTimeMs"]) ?? 0 }
        let lines = rawLines.enumerated().map { index, rawLine in
            let start = starts[index]
            let end = index + 1 < starts.count ? starts[index + 1] : start + 10_000
            let rawSyllables = rawLine["syllables"] as? [[String: Any]] ?? []
            let syllables = rawSyllables.compactMap { raw -> Syllable? in
                guard let syllableStart = integer(raw["startTimeMs"]), let count = integer(raw["count"]) else {
                    return nil
                }
                return Syllable(startTimeMs: syllableStart, count: count)
            }
            return LyricLine(
                startTimeMs: start,
                endTimeMs: end,
                words: rawLine["words"] as? String ?? "",
                syllables: syllables
            )
        }

        return Lyrics(
            syncType: payload["syncType"] as? String ?? "UNSYNCED",
            lines: lines,
            provider: payload["provider"] as? String,
            language: payload["language"] as? String
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }
}
