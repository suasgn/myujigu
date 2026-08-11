import AppKit
import Combine
import Foundation
import MyujiguCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var playerState: PlayerState = .stopped
    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var lyricsSource: LyricsSource?
    @Published private(set) var lyricsError: String?
    @Published private(set) var isLoadingLyrics = false
    @Published private(set) var activeLineIndex: Int?
    @Published private(set) var menuBarText = "Myujigu"
    @Published private(set) var hasCredential = false
    @Published var settingsMessage: String?

    private let player = SpotifyPlayer()
    private let appleMusicPlayer = AppleMusicPlayer()
    private let cefCache = CEFLyricsCache()
    private let appleMusicCache = AppleMusicLyricsCache()
    private let credentials = CredentialStore()
    private var api: SpotifyAPI?
    private var activePlayer: PlayerKind?
    private var pollTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private let lyricsRetryNanoseconds: UInt64 = 3_000_000_000

    init() {
        hasCredential = credentials.load() != nil
    }

    deinit {
        pollTask?.cancel()
        lyricsTask?.cancel()
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPlayer()
                let interval = self?.playerPollIntervalNanoseconds ?? 2_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        lyricsTask?.cancel()
        lyricsTask = nil
    }

    func send(_ command: SpotifyCommand) {
        Task { [weak self] in
            guard let self else { return }
            if playerState.player == .appleMusic {
                await appleMusicPlayer.send(command)
            } else {
                await player.send(command)
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            await refreshPlayer()
        }
    }

    @discardableResult
    func saveCredential(_ value: String) -> Bool {
        do {
            try credentials.save(value)
            hasCredential = credentials.load() != nil
            settingsMessage = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Spotify login removed."
                : "Spotify login saved securely in Keychain."
            api = nil
            reloadLyrics()
            return true
        } catch {
            settingsMessage = error.localizedDescription
            return false
        }
    }

    func reloadLyrics() {
        guard let trackID = playerState.trackID else { return }
        beginLoadingLyrics(
            trackID: trackID,
            player: playerState.player,
            force: true
        )
    }

    var currentLine: LyricLine? {
        guard let lyrics, let activeLineIndex, lyrics.lines.indices.contains(activeLineIndex) else { return nil }
        return lyrics.lines[activeLineIndex]
    }

    var playbackDescription: String {
        switch playerState.status {
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .stopped: return "Nothing playing"
        case .unavailable:
            return playerState.player == .appleMusic
                ? "Music unavailable"
                : "Spotify unavailable"
        }
    }

    private var playerPollIntervalNanoseconds: UInt64 {
        switch playerState.status {
        case .playing:
            // The marquee interpolates from this position anchor, so it does
            // not need to launch osascript for every animation update.
            return 1_000_000_000
        case .paused, .stopped, .unavailable:
            return 2_000_000_000
        }
    }

    private func refreshPlayer() async {
        let freshState = await readCurrentPlayerState()
        guard !Task.isCancelled else { return }

        let oldTrackID = playerState.trackID
        playerState = freshState

        if freshState.trackID != oldTrackID {
            lyricsTask?.cancel()
            lyrics = nil
            lyricsSource = nil
            lyricsError = nil
            activeLineIndex = nil

            if let trackID = freshState.trackID {
                beginLoadingLyrics(trackID: trackID, player: freshState.player)
            } else {
                isLoadingLyrics = false
            }
        }

        updateActiveLine()
        updateMenuBarText()
    }

    private func readCurrentPlayerState() async -> PlayerState {
        var fallback: PlayerState?
        var candidates: [PlayerKind] = []
        if let activePlayer {
            candidates.append(activePlayer)
        }
        for candidate in [PlayerKind.spotify, .appleMusic] where !candidates.contains(candidate) {
            candidates.append(candidate)
        }

        for candidate in candidates where isRunning(candidate) {
            let state: PlayerState
            switch candidate {
            case .spotify:
                state = await player.currentState()
            case .appleMusic:
                state = await appleMusicPlayer.currentState()
            }

            if state.trackID != nil,
               (state.status == .playing || state.status == .paused)
            {
                activePlayer = candidate
                return state
            }
            if fallback == nil
                || (fallback?.status == .unavailable && state.status != .unavailable)
            {
                fallback = state
            }
        }

        activePlayer = nil
        return fallback ?? .stopped
    }

    private func isRunning(_ player: PlayerKind) -> Bool {
        let bundleIdentifier = switch player {
        case .spotify: "com.spotify.client"
        case .appleMusic: "com.apple.Music"
        }
        return NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).contains { !$0.isTerminated }
    }

    private func beginLoadingLyrics(
        trackID: String,
        player sourcePlayer: PlayerKind?,
        force: Bool = false
    ) {
        lyricsTask?.cancel()
        isLoadingLyrics = true
        lyricsError = nil
        if force {
            lyrics = nil
            lyricsSource = nil
            activeLineIndex = nil
        }

        lyricsTask = Task { [weak self] in
            guard let self else { return }
            var appleMusicPlainLyrics: String?

            while !Task.isCancelled, playerState.trackID == trackID {
                if sourcePlayer == .appleMusic {
                    if appleMusicPlainLyrics == nil {
                        appleMusicPlainLyrics = await appleMusicPlayer.currentLyrics()
                    }
                    if let cached = await appleMusicCache.findLyrics(
                        title: playerState.title,
                        durationMs: playerState.durationMs,
                        plainLyrics: appleMusicPlainLyrics
                    ) {
                        guard !Task.isCancelled, playerState.trackID == trackID else { return }
                        install(cached, source: .appleMusicCache)
                        return
                    }
                    recordLyricsFailure("Waiting for Apple Music's synchronized lyrics cache.")
                    do {
                        try await Task.sleep(nanoseconds: lyricsRetryNanoseconds)
                    } catch {
                        return
                    }
                    continue
                }

                if let cached = await cefCache.findLyrics(trackID: trackID) {
                    guard !Task.isCancelled, playerState.trackID == trackID else { return }
                    install(cached, source: .spotifyCache)
                    return
                }

                guard !Task.isCancelled, playerState.trackID == trackID else { return }

                if let cookie = credentials.load(), !cookie.isEmpty {
                    if api == nil {
                        api = SpotifyAPI(cookie: cookie)
                    }

                    do {
                        let fetched = try await api?.fetchLyrics(trackID: trackID)
                        guard !Task.isCancelled, playerState.trackID == trackID else { return }
                        if let fetched {
                            install(fetched, source: .spotifyAPI)
                            return
                        }
                        recordLyricsFailure("No lyrics are available for this track.")
                    } catch {
                        guard !Task.isCancelled, playerState.trackID == trackID else { return }
                        recordLyricsFailure(error.localizedDescription)
                    }
                } else {
                    recordLyricsFailure(
                        "No cached lyrics. Sign in with Spotify in Settings."
                    )
                }

                do {
                    try await Task.sleep(nanoseconds: lyricsRetryNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    private func recordLyricsFailure(_ message: String) {
        isLoadingLyrics = false
        lyricsError = message
        updateMenuBarText()
    }

    private func install(_ newLyrics: Lyrics, source: LyricsSource) {
        lyrics = newLyrics
        lyricsSource = source
        lyricsError = nil
        isLoadingLyrics = false
        updateActiveLine()
        updateMenuBarText()
    }

    private func updateActiveLine() {
        activeLineIndex = lyrics?.activeLineIndex(at: playerState.positionMs)
    }

    private func updateMenuBarText() {
        if let currentLine, !currentLine.words.isEmpty {
            menuBarText = currentLine.words
            return
        }
        if playerState.status == .unavailable {
            menuBarText = ""
        } else if playerState.trackID == nil {
            menuBarText = ""
        } else if isLoadingLyrics {
            menuBarText = "Loading lyrics…"
        } else {
            menuBarText = ""
        }
    }
}
