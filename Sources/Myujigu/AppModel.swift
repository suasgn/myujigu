import AppKit
import Combine
import Foundation
import ImageIO
import MyujiguCore

enum MenuBarLyricsLayout: String, CaseIterable, Identifiable {
    case automatic
    case fixed

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .fixed: return "Fixed"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    private enum ArtworkCache {
        static let countLimit = 6
        static let totalCostLimit = 16 * 1_024 * 1_024
        static let maximumPixelSize = 512
    }

    @Published private(set) var playerState: PlayerState = .stopped
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var lyricsSource: LyricsSource?
    @Published private(set) var lyricsError: String?
    @Published private(set) var isLoadingLyrics = false
    @Published private(set) var activeLineIndex: Int?
    @Published private(set) var menuBarText = "Myujigu"
    @Published private(set) var showsMenuBarLyrics = false
    @Published private(set) var hasCredential = false
    @Published var settingsMessage: String?
    @Published var menuBarLyricsLeftLayout: MenuBarLyricsLayout = {
        let defaults = UserDefaults.standard
        if let rawValue = defaults.string(forKey: "menuBarLyricsLeftLayout"),
           let layout = MenuBarLyricsLayout(rawValue: rawValue) {
            return layout
        }
        switch defaults.string(forKey: "menuBarLyricsLayout") {
        case MenuBarLyricsLayout.fixed.rawValue, "fixedLeft": return .fixed
        default: return .automatic
        }
    }() {
        didSet {
            UserDefaults.standard.set(
                menuBarLyricsLeftLayout.rawValue,
                forKey: "menuBarLyricsLeftLayout"
            )
        }
    }
    @Published var menuBarLyricsRightLayout: MenuBarLyricsLayout = {
        let defaults = UserDefaults.standard
        if let rawValue = defaults.string(forKey: "menuBarLyricsRightLayout"),
           let layout = MenuBarLyricsLayout(rawValue: rawValue) {
            return layout
        }
        switch defaults.string(forKey: "menuBarLyricsLayout") {
        case MenuBarLyricsLayout.fixed.rawValue, "fixedRight": return .fixed
        default: return .automatic
        }
    }() {
        didSet {
            UserDefaults.standard.set(
                menuBarLyricsRightLayout.rawValue,
                forKey: "menuBarLyricsRightLayout"
            )
        }
    }
    @Published var fixedMenuBarLyricsLeftWidth: Double = {
        let defaults = UserDefaults.standard
        let savedWidth = (defaults.object(forKey: "fixedMenuBarLyricsLeftWidth") as? NSNumber)?
            .doubleValue
            ?? (defaults.object(forKey: "fixedMenuBarLyricsWidth") as? NSNumber)?.doubleValue
        return min(max(savedWidth ?? 360, 120), 1_200)
    }() {
        didSet {
            let clampedWidth = min(max(fixedMenuBarLyricsLeftWidth, 120), 1_200)
            if fixedMenuBarLyricsLeftWidth != clampedWidth {
                fixedMenuBarLyricsLeftWidth = clampedWidth
                return
            }
            UserDefaults.standard.set(
                fixedMenuBarLyricsLeftWidth,
                forKey: "fixedMenuBarLyricsLeftWidth"
            )
        }
    }
    @Published var fixedMenuBarLyricsRightWidth: Double = {
        let defaults = UserDefaults.standard
        let savedWidth = (defaults.object(forKey: "fixedMenuBarLyricsRightWidth") as? NSNumber)?
            .doubleValue
            ?? (defaults.object(forKey: "fixedMenuBarLyricsWidth") as? NSNumber)?.doubleValue
        return min(max(savedWidth ?? 360, 120), 1_200)
    }() {
        didSet {
            let clampedWidth = min(max(fixedMenuBarLyricsRightWidth, 120), 1_200)
            if fixedMenuBarLyricsRightWidth != clampedWidth {
                fixedMenuBarLyricsRightWidth = clampedWidth
                return
            }
            UserDefaults.standard.set(
                fixedMenuBarLyricsRightWidth,
                forKey: "fixedMenuBarLyricsRightWidth"
            )
        }
    }

    private let player = SpotifyPlayer()
    private let appleMusicPlayer = AppleMusicPlayer()
    private let systemPlayer = SystemNowPlayingPlayer()
    private let cefCache = CEFLyricsCache()
    private let appleMusicCache = AppleMusicLyricsCache()
    private let lrclib = LRCLIBClient()
    private let credentials = CredentialStore()
    private let artworkCache = NSCache<NSString, NSImage>()
    private var api: SpotifyAPI?
    private var activePlayer: PlayerKind?
    private var pollTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var pauseVisibilityTask: Task<Void, Never>?
    private let lyricsRetryNanoseconds: UInt64 = 3_000_000_000
    private let pauseHideDelayNanoseconds: UInt64 = 5_000_000_000

    init() {
        hasCredential = credentials.load() != nil
        artworkCache.countLimit = ArtworkCache.countLimit
        artworkCache.totalCostLimit = ArtworkCache.totalCostLimit
    }

    deinit {
        pollTask?.cancel()
        lyricsTask?.cancel()
        artworkTask?.cancel()
        pauseVisibilityTask?.cancel()
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
        artworkTask?.cancel()
        artworkTask = nil
        pauseVisibilityTask?.cancel()
        pauseVisibilityTask = nil
    }

    func send(_ command: SpotifyCommand) {
        Task { [weak self] in
            guard let self else { return }
            switch playerState.player {
            case .appleMusic:
                await appleMusicPlayer.send(command)
            case .spotify:
                await player.send(command)
            case .system:
                await systemPlayer.send(command)
            case nil:
                return
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
            switch playerState.player {
            case .appleMusic: return "Music unavailable"
            case .spotify: return "Spotify unavailable"
            case .system: return "Now Playing unavailable"
            case nil: return "Player unavailable"
            }
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

        let oldState = playerState
        let oldTrackID = playerState.trackID
        playerState = freshState
        updateMenuBarLyricsVisibility(from: oldState, to: freshState)

        if freshState.trackID != oldTrackID {
            lyricsTask?.cancel()
            artworkTask?.cancel()
            artworkImage = nil
            lyrics = nil
            lyricsSource = nil
            lyricsError = nil
            activeLineIndex = nil

            if let trackID = freshState.trackID {
                beginLoadingArtwork(for: freshState)
                beginLoadingLyrics(trackID: trackID, player: freshState.player)
            } else {
                isLoadingLyrics = false
            }
        }

        updateActiveLine()
        updateMenuBarText()
    }

    private func updateMenuBarLyricsVisibility(
        from oldState: PlayerState,
        to newState: PlayerState
    ) {
        switch newState.status {
        case .playing:
            pauseVisibilityTask?.cancel()
            pauseVisibilityTask = nil
            showsMenuBarLyrics = newState.trackID != nil

        case .paused:
            let pauseJustStarted = oldState.status != .paused
                || oldState.trackID != newState.trackID
            guard pauseJustStarted else { return }

            pauseVisibilityTask?.cancel()
            showsMenuBarLyrics = newState.trackID != nil
            let pausedTrackID = newState.trackID
            let hideDelay = pauseHideDelayNanoseconds
            pauseVisibilityTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: hideDelay)
                } catch {
                    return
                }
                guard let self,
                      playerState.status == .paused,
                      playerState.trackID == pausedTrackID
                else {
                    return
                }
                showsMenuBarLyrics = false
                pauseVisibilityTask = nil
            }

        case .stopped, .unavailable:
            pauseVisibilityTask?.cancel()
            pauseVisibilityTask = nil
            showsMenuBarLyrics = false
        }
    }

    private func beginLoadingArtwork(for state: PlayerState) {
        guard let trackID = state.trackID else { return }
        let cacheKey = "\(state.player?.rawValue ?? "unknown"):\(trackID)" as NSString
        if let cachedImage = artworkCache.object(forKey: cacheKey) {
            artworkImage = cachedImage
            return
        }

        artworkTask = Task { [weak self] in
            guard let self else { return }
            let data: Data?
            switch state.player {
            case .spotify:
                data = await remoteArtworkData(from: state.artworkURL)
            case .appleMusic:
                data = await appleMusicPlayer.currentArtworkData()
            case .system:
                data = await systemPlayer.currentArtworkData()
            case nil:
                data = nil
            }

            guard !Task.isCancelled,
                  playerState.trackID == trackID,
                  let data,
                  let artwork = makeCachedArtwork(from: data)
            else {
                return
            }
            artworkCache.setObject(artwork.image, forKey: cacheKey, cost: artwork.cost)
            artworkImage = artwork.image
        }
    }

    private func makeCachedArtwork(from data: Data) -> (image: NSImage, cost: Int)? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: ArtworkCache.maximumPixelSize,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions
        ) else {
            return nil
        }

        let (decodedByteCount, overflowed) = thumbnail.bytesPerRow.multipliedReportingOverflow(
            by: thumbnail.height
        )
        let cost = overflowed ? ArtworkCache.totalCostLimit : decodedByteCount
        let image = NSImage(
            cgImage: thumbnail,
            size: NSSize(width: thumbnail.width, height: thumbnail.height)
        )
        return (image, cost)
    }

    private func remoteArtworkData(from url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 15
        )
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  !data.isEmpty,
                  data.count <= 20 * 1_024 * 1_024
            else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func readCurrentPlayerState() async -> PlayerState {
        var fallback: PlayerState?
        var pausedCandidate: (player: PlayerKind, state: PlayerState)?
        var candidates: [PlayerKind] = []
        if let activePlayer, activePlayer != .system {
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
            case .system:
                continue
            }

            if state.trackID != nil, state.status == .playing {
                activePlayer = candidate
                return state
            }
            if state.trackID != nil,
               state.status == .paused,
               pausedCandidate == nil
            {
                // Keep this as a fallback, but continue checking whether the
                // other open player has started playback.
                pausedCandidate = (candidate, state)
            }
            if fallback == nil
                || (fallback?.status == .unavailable && state.status != .unavailable)
            {
                fallback = state
            }
        }

        let systemState = await systemPlayer.currentState()
        let representsNativePlayer = SystemNowPlayingPlayer.isNativePlayer(
            bundleIdentifier: systemState.bundleIdentifier,
            sourceName: systemState.sourceName
        )
        if !representsNativePlayer,
           systemState.trackID != nil,
           systemState.status == .playing
        {
            activePlayer = .system
            return systemState
        }

        // Control Center identifies the most recently active paused session,
        // which is more useful than an arbitrary paused native app.
        if !representsNativePlayer,
           systemState.trackID != nil,
           systemState.status == .paused
        {
            activePlayer = .system
            return systemState
        }

        if let pausedCandidate {
            activePlayer = pausedCandidate.player
            return pausedCandidate.state
        }

        activePlayer = nil
        if !representsNativePlayer, systemState.status == .unavailable {
            return fallback ?? systemState
        }
        return fallback ?? .stopped
    }

    private func isRunning(_ player: PlayerKind) -> Bool {
        let bundleIdentifier: String
        switch player {
        case .spotify:
            bundleIdentifier = "com.spotify.client"
        case .appleMusic:
            bundleIdentifier = "com.apple.Music"
        case .system:
            return false
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

            if sourcePlayer == .system {
                let state = playerState
                guard !SystemNowPlayingPlayer.isNativePlayer(
                    bundleIdentifier: state.bundleIdentifier,
                    sourceName: state.sourceName
                ) else {
                    recordLyricsFailure("Spotify and Apple Music use their native lyric sources.")
                    return
                }
                guard !state.title.isEmpty, !state.artist.isEmpty else {
                    recordLyricsFailure(
                        "This player did not provide enough track metadata for LRCLIB."
                    )
                    return
                }
                do {
                    let fetched = try await lrclib.fetchLyrics(
                        title: state.title,
                        artist: state.artist,
                        album: state.album,
                        durationMs: state.durationMs,
                        ignoreCache: force
                    )
                    guard !Task.isCancelled, playerState.trackID == trackID else { return }
                    if let fetched {
                        install(fetched, source: .lrclib)
                    } else {
                        recordLyricsFailure("LRCLIB has no lyrics for this track.")
                    }
                } catch {
                    guard !Task.isCancelled, playerState.trackID == trackID else { return }
                    recordLyricsFailure(error.localizedDescription)
                }
                return
            }

            var appleMusicPlainLyrics: String?

            while !Task.isCancelled, playerState.trackID == trackID {
                if sourcePlayer == .appleMusic {
                    if appleMusicPlainLyrics == nil {
                        appleMusicPlainLyrics = await appleMusicPlayer.currentLyrics()
                    }
                    if let cached = await appleMusicCache.findLyrics(
                        title: playerState.title,
                        durationMs: playerState.durationMs,
                        artist: playerState.artist,
                        album: playerState.album,
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
