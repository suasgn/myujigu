import Foundation

public enum SpotifyCommand: Sendable {
    case playPause
    case next
    case previous
}

public struct SpotifyPlayer: Sendable {
    private static let separator = Character(UnicodeScalar(31))

    private static let stateScript = #"""
    on run
      tell application "Spotify"
        if player state is stopped then
          return "stopped"
        end if
        set unitSeparator to ASCII character 31
        set trackIdentifier to id of current track
        set positionMilliseconds to ((player position) * 1000) as integer
        set playbackState to (player state as string)
        set trackName to name of current track
        set trackArtist to artist of current track
        return playbackState & unitSeparator & positionMilliseconds & unitSeparator & trackIdentifier & unitSeparator & trackName & unitSeparator & trackArtist
      end tell
    end run
    """#

    public init() {}

    public func currentState() async -> PlayerState {
        await Task.detached(priority: .utility) {
            let result = Self.runAppleScript(Self.stateScript)
            guard result.status == 0 else {
                return PlayerState(
                    status: .unavailable,
                    player: .spotify,
                    trackID: nil,
                    positionMs: 0,
                    title: "",
                    artist: ""
                )
            }
            return Self.parseState(result.output)
        }.value
    }

    public func send(_ command: SpotifyCommand) async {
        let statement: String
        switch command {
        case .playPause:
            statement = "playpause"
        case .next:
            statement = "next track"
        case .previous:
            statement = "previous track"
        }
        await Task.detached(priority: .userInitiated) {
            _ = Self.runAppleScript("tell application \"Spotify\" to \(statement)")
        }.value
    }

    public static func parseState(_ output: String) -> PlayerState {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "stopped" || trimmed.isEmpty {
            return .stopped
        }

        let fields = trimmed.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5 else {
            return PlayerState(
                status: .unavailable,
                player: .spotify,
                trackID: nil,
                positionMs: 0,
                title: "",
                artist: ""
            )
        }

        let status = PlayerStatus(rawValue: fields[0]) ?? .unavailable
        let spotifyURI = fields[2]
        let trackID = spotifyURI.hasPrefix("spotify:track:")
            ? String(spotifyURI.dropFirst("spotify:track:".count))
            : nil

        return PlayerState(
            status: status,
            player: .spotify,
            trackID: trackID,
            positionMs: Int(fields[1]) ?? 0,
            title: fields[3],
            artist: fields[4]
        )
    }

    private static func runAppleScript(_ source: String) -> (status: Int32, output: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, "")
        }
    }
}
