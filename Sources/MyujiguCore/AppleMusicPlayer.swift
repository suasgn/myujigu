import Foundation

public struct AppleMusicPlayer: Sendable {
    private static let separator = Character(UnicodeScalar(31))

    private static let artworkScript = #"""
    on run argv
      set destinationPath to item 1 of argv
      set fileReference to missing value
      tell application "Music"
        try
          set currentSong to current track
          if (count of artworks of currentSong) is 0 then return ""
          try
            set artworkData to raw data of artwork 1 of currentSong
          on error
            set artworkData to data of artwork 1 of currentSong
          end try
        on error
          return ""
        end try
      end tell

      try
        set destinationFile to POSIX file destinationPath
        set fileReference to open for access destinationFile with write permission
        set eof fileReference to 0
        write artworkData to fileReference
        close access fileReference
        return destinationPath
      on error
        try
          if fileReference is not missing value then close access fileReference
        end try
        return ""
      end try
    end run
    """#

    private static let stateScript = #"""
    on run
      tell application "Music"
        if player state is stopped then
          return "stopped"
        end if
        set unitSeparator to ASCII character 31
        set currentSong to current track
        set trackIdentifier to persistent ID of currentSong
        set positionMilliseconds to ((player position) * 1000) as integer
        set playbackState to (player state as string)
        set trackName to name of currentSong
        set trackArtist to artist of currentSong
        set trackAlbum to album of currentSong
        set durationMilliseconds to ((duration of currentSong) * 1000) as integer
        return playbackState & unitSeparator & positionMilliseconds & unitSeparator & trackIdentifier & unitSeparator & trackName & unitSeparator & trackArtist & unitSeparator & trackAlbum & unitSeparator & durationMilliseconds
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
                    player: .appleMusic,
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
            _ = Self.runAppleScript("tell application \"Music\" to \(statement)")
        }.value
    }

    public func currentLyrics() async -> String? {
        await Task.detached(priority: .utility) {
            let source = #"""
            tell application "Music"
              try
                return lyrics of current track
              on error
                return ""
              end try
            end tell
            """#
            let result = Self.runAppleScript(source)
            guard result.status == 0 else { return nil }
            let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.value
    }

    public func currentArtworkData() async -> Data? {
        await Task.detached(priority: .utility) {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("myujigu-artwork-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: destination) }

            let result = Self.runAppleScript(
                Self.artworkScript,
                arguments: [destination.path]
            )
            guard result.status == 0,
                  !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return try? Data(contentsOf: destination)
        }.value
    }

    public static func parseState(_ output: String) -> PlayerState {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "stopped" || trimmed.isEmpty {
            return PlayerState(
                status: .stopped,
                player: .appleMusic,
                trackID: nil,
                positionMs: 0,
                title: "",
                artist: ""
            )
        }

        let fields = trimmed.split(separator: separator, omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count >= 7 else {
            return PlayerState(
                status: .unavailable,
                player: .appleMusic,
                trackID: nil,
                positionMs: 0,
                title: "",
                artist: ""
            )
        }

        let persistentID = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return PlayerState(
            status: PlayerStatus(rawValue: fields[0]) ?? .unavailable,
            player: .appleMusic,
            trackID: persistentID.isEmpty ? nil : "apple-music:\(persistentID)",
            positionMs: Int(fields[1]) ?? 0,
            title: fields[3],
            artist: fields[4],
            album: fields[5],
            durationMs: Int(fields[6]) ?? 0
        )
    }

    private static func runAppleScript(
        _ source: String,
        arguments: [String] = []
    ) -> (status: Int32, output: String) {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source] + arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, "")
        }
    }
}
