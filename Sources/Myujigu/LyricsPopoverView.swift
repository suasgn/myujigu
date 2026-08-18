import AppKit
import MyujiguCore
import SwiftUI

struct LyricsPopoverView: View {
    @ObservedObject var model: AppModel
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 0) {
            playerRail
                .frame(width: PanelLayout.railWidth)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)

            lyricsPane
        }
        .frame(width: PanelLayout.width, height: PanelLayout.height)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model, accent: accent)
        }
    }

    private var playerRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand

            Spacer(minLength: 18)

            ArtworkTile(
                image: model.artworkImage,
                symbol: playerSymbol,
                accent: accent
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(trackTitle)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(trackArtist)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !model.playerState.album.isEmpty {
                    Text(model.playerState.album)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 16)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(model.playbackDescription)
                    .lineLimit(1)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .padding(.top, 12)

            Spacer(minLength: 14)

            if model.playerState.durationMs > 0 {
                playbackTimeline
                    .padding(.bottom, 13)
            }

            playbackControls

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 14)

            HStack(spacing: 8) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Quit Myujigu")
                .accessibilityLabel("Quit Myujigu")
            }
        }
        .padding(18)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                LinearGradient(
                    colors: [accent.opacity(0.16), accent.opacity(0.035), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var brand: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent)
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 25, height: 25)

            VStack(alignment: .leading, spacing: 0) {
                Text("MYUJIGU")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.1)
                Text(playerName)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var playbackTimeline: some View {
        VStack(spacing: 6) {
            ProgressView(value: playbackProgress)
                .progressViewStyle(.linear)
                .tint(accent)

            HStack {
                Text(formatTime(model.playerState.positionMs))
                Spacer()
                Text(formatTime(model.playerState.durationMs))
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 15) {
            transportButton("backward.fill", label: "Previous") {
                model.send(.previous)
            }

            Button { model.send(.playPause) } label: {
                Image(systemName: model.playerState.status == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(accent, in: Circle())
                    .shadow(color: accent.opacity(0.22), radius: 8, y: 4)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.playerState.status == .playing ? "Pause" : "Play")
            .accessibilityLabel(model.playerState.status == .playing ? "Pause" : "Play")

            transportButton("forward.fill", label: "Next") {
                model.send(.next)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var lyricsPane: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lyrics")
                        .font(.system(size: 17, weight: .bold))
                    Text(lyricsDescriptor)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                if model.isLoadingLyrics {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                } else if model.lyrics != nil {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 30, height: 30)
                        .background(accent.opacity(0.1), in: Circle())
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 62)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
            }

            Group {
                if let lyrics = model.lyrics {
                    LyricsStage(
                        lyrics: lyrics,
                        activeIndex: model.activeLineIndex,
                        positionMs: model.playerState.positionMs,
                        liveHighlight: model.realtimeWordHighlightingEnabled
                            ? model.liveWordHighlight
                            : nil,
                        accent: accent
                    )
                } else {
                    EmptyLyricsStage(
                        state: emptyState,
                        accent: accent,
                        retry: model.playerState.trackID == nil ? nil : {
                            model.reloadLyrics()
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
    }

    private var accent: Color {
        Color(nsColor: model.mainThemeColor)
    }

    private var playerSymbol: String {
        switch model.playerState.player {
        case .appleMusic: return "music.note"
        case .spotify: return "waveform"
        case .system: return "hifispeaker.fill"
        case nil: return "waveform"
        }
    }

    private var playerName: String {
        switch model.playerState.player {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .system: return model.playerState.sourceName ?? "Now Playing"
        case nil: return "Menu bar lyrics"
        }
    }

    private var trackTitle: String {
        model.playerState.title.isEmpty ? "Nothing playing" : model.playerState.title
    }

    private var trackArtist: String {
        model.playerState.artist.isEmpty ? "Start a song to begin" : model.playerState.artist
    }

    private var statusColor: Color {
        switch model.playerState.status {
        case .playing: return accent
        case .paused: return .orange
        case .stopped, .unavailable: return .secondary
        }
    }

    private var playbackProgress: Double {
        guard model.playerState.durationMs > 0 else { return 0 }
        return min(max(
            Double(model.playerState.positionMs) / Double(model.playerState.durationMs),
            0
        ), 1)
    }

    private var lyricsDescriptor: String {
        guard let lyrics = model.lyrics else {
            return model.isLoadingLyrics ? "Finding synchronized lyrics…" : "Waiting for playback"
        }
        var parts: [String] = []
        if let source = model.lyricsSource {
            parts.append(source.rawValue)
        }
        if let language = lyrics.language, !language.isEmpty {
            parts.append(language.uppercased())
        }
        parts.append(lyrics.syncType.uppercased() == "UNSYNCED" ? "PLAIN" : "SYNCED")
        return parts.joined(separator: "  ·  ")
    }

    private var emptyState: EmptyLyricsState {
        if model.isLoadingLyrics {
            return EmptyLyricsState(
                isLoading: true,
                symbol: "waveform",
                title: "Finding lyrics",
                message: "Checking local caches and connected services for this track."
            )
        }
        if model.playerState.status == .unavailable {
            let message: String
            switch model.playerState.player {
            case .appleMusic:
                message = "Open Music, then allow Automation access in System Settings."
            case .spotify:
                message = "Open Spotify, then allow Automation access in System Settings."
            case .system:
                message = "macOS did not provide a readable Now Playing session."
            case nil:
                message = "Start a supported media player and try again."
            }
            return EmptyLyricsState(
                isLoading: false,
                symbol: "exclamationmark.triangle",
                title: "Player unavailable",
                message: message
            )
        }
        if model.playerState.trackID == nil {
            return EmptyLyricsState(
                isLoading: false,
                symbol: "music.note",
                title: "Ready when you are",
                message: "Play something in a macOS Now Playing-compatible app. Lyrics will settle into this space automatically."
            )
        }
        return EmptyLyricsState(
            isLoading: false,
            symbol: "text.quote",
            title: "No lyrics yet",
            message: model.lyricsError ?? "Synchronized lyrics are not available for this track."
        )
    }

    private func formatTime(_ milliseconds: Int) -> String {
        let seconds = max(milliseconds, 0) / 1_000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ArtworkTile: View {
    let image: NSImage?
    let symbol: String
    let accent: Color

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.18)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 27, height: 27)
                            .background(.black.opacity(0.38), in: Circle())
                    }
                }
                .padding(10)
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.58), Color.black.opacity(0.82)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .stroke(.white.opacity(0.13), lineWidth: 18)
                    .frame(width: 98, height: 98)
                    .offset(x: 38, y: 36)

                Circle()
                    .fill(.black.opacity(0.22))
                    .frame(width: 53, height: 53)

                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        }
        .shadow(color: accent.opacity(0.18), radius: 16, y: 8)
        .animation(.easeInOut(duration: 0.25), value: image != nil)
    }
}

private struct LyricsStage: View {
    let lyrics: Lyrics
    let activeIndex: Int?
    let positionMs: Int
    let liveHighlight: LiveWordHighlight?
    let accent: Color

    private var displayedActiveIndex: Int? {
        liveHighlight?.lineIndex ?? activeIndex
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        StageLyricLine(
                            line: line,
                            isActive: index == displayedActiveIndex,
                            hasPassed: index < (displayedActiveIndex ?? 0),
                            positionMs: positionMs,
                            liveHighlight: liveHighlight?.lineIndex == index
                                ? liveHighlight
                                : nil,
                            accent: accent
                        )
                        .id(index)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 20)
            }
            .onAppear {
                DispatchQueue.main.async {
                    scrollToActiveLine(with: proxy, animated: false)
                }
            }
            .onChange(of: activeIndex) { _ in
                scrollToActiveLine(with: proxy, animated: true)
            }
            .onChange(of: liveHighlight?.lineIndex) { _ in
                scrollToActiveLine(with: proxy, animated: true)
            }
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.045),
                    .init(color: .black, location: 0.955),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func scrollToActiveLine(with proxy: ScrollViewProxy, animated: Bool) {
        guard let activeIndex = displayedActiveIndex else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.32)) {
                proxy.scrollTo(activeIndex, anchor: .center)
            }
        } else {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
    }
}

private struct StageLyricLine: View {
    let line: LyricLine
    let isActive: Bool
    let hasPassed: Bool
    let positionMs: Int
    let liveHighlight: LiveWordHighlight?
    let accent: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(formatTime(line.startTimeMs))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 31, alignment: .trailing)

            karaokeText
                .font(
                    isActive
                        ? .system(size: 19, weight: .bold)
                        : .system(size: 13.5, weight: .medium)
                )
                .lineSpacing(3)
                .opacity(isActive ? 1 : (hasPassed ? 0.28 : 0.58))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isActive ? 13 : 8)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isActive ? accent.opacity(0.09) : .clear)
        }
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(accent)
                    .frame(width: 3, height: 28)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isActive)
    }

    private var karaokeText: Text {
        if isActive, let liveHighlight {
            let words = line.words as NSString
            let range = NSRange(
                location: liveHighlight.utf16Offset,
                length: liveHighlight.utf16Length
            )
            if range.location >= 0, NSMaxRange(range) <= words.length {
                return Text(words.substring(to: range.location))
                    + Text(words.substring(with: range)).foregroundColor(accent)
                    + Text(words.substring(from: NSMaxRange(range)))
            }
        }

        guard isActive, !line.syllables.isEmpty else {
            return Text(line.words)
        }

        let completed = line.syllables
            .prefix(while: { $0.startTimeMs <= positionMs })
            .reduce(0) { $0 + $1.count }
        let characters = Array(line.words)
        let split = min(max(completed, 0), characters.count)
        return Text(String(characters[..<split])).foregroundColor(accent)
            + Text(String(characters[split...])).foregroundColor(.primary)
    }

    private func formatTime(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct EmptyLyricsState {
    let isLoading: Bool
    let symbol: String
    let title: String
    let message: String
}

private struct EmptyLyricsStage: View {
    let state: EmptyLyricsState
    let accent: Color
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 13) {
            Spacer()

            ZStack {
                Circle()
                    .fill(accent.opacity(0.09))
                    .frame(width: 68, height: 68)

                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                } else {
                    Image(systemName: state.symbol)
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(accent)
                }
            }

            Text(state.title)
                .font(.system(size: 18, weight: .bold))

            Text(state.message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 250)

            if let retry, !state.isLoading {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(accent)
            }

            Spacer()
        }
        .padding(24)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    let accent: Color

    @Environment(\.dismiss) private var dismiss
    @State private var showingSpotifyLogin = false

    var body: some View {
        HStack(spacing: 0) {
            settingsRail
                .frame(width: 154)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)

            settingsContent
        }
        .frame(width: 540, height: 680)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showingSpotifyLogin) {
            SpotifyLoginView { cookie in
                model.saveCredential(cookie)
            }
        }
    }

    private var settingsRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.58)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "music.note")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 62, height: 62)
            .shadow(color: accent.opacity(0.2), radius: 12, y: 6)

            Text("Myujigu")
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 14)

            Text("Menu bar lyrics")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Spacer()

            Label("Private session", systemImage: "lock.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            LinearGradient(
                colors: [accent.opacity(0.15), accent.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings")
                        .font(.system(size: 19, weight: .bold))
                    Text("Menu bar, connections, and privacy")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 24)

            Text("MENU BAR LYRICS")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.tertiary)

            VStack(spacing: 8) {
                menuBarLaneControls(
                    "Left",
                    layout: $model.menuBarLyricsLeftLayout,
                    value: $model.fixedMenuBarLyricsLeftWidth
                )
                menuBarLaneControls(
                    "Right",
                    layout: $model.menuBarLyricsRightLayout,
                    value: $model.fixedMenuBarLyricsRightWidth
                )
            }
            .padding(.top, 10)

            Text("Each side can use safe available space or a fixed width extending outward from the screen center or notch.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 18)

            Text("REALTIME KARAOKE")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.tertiary)

            Toggle(isOn: $model.realtimeWordHighlightingEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Highlight the current word")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("Uses provider word timing when available and estimates words within each synchronized line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.top, 11)

            Label(
                model.realtimeKaraokeStatus.message,
                systemImage: model.realtimeKaraokeStatus.isFollowingTiming
                    ? "waveform.circle.fill"
                    : "info.circle"
            )
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(
                model.realtimeKaraokeStatus.isFollowingTiming ? accent : Color.secondary
            )
            .padding(.top, 8)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 18)

            Text("SPOTIFY")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 11) {
                Image(systemName: model.hasCredential ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 19))
                    .foregroundStyle(model.hasCredential ? accent : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.hasCredential ? "Connected" : "Not connected")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("Used only when Spotify’s desktop cache has no lyrics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 13)

            HStack {
                Button(model.hasCredential ? "Sign In Again" : "Sign In with Spotify") {
                    showingSpotifyLogin = true
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)

                Button("Remove", role: .destructive) {
                    model.saveCredential("")
                }
                .disabled(!model.hasCredential)

                Spacer()
            }

            if let message = model.settingsMessage {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 18)

            Text("PRIVACY")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.tertiary)

            Label("Temporary browser, Keychain storage", systemImage: "lock.shield.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.top, 12)

            Text("The sign-in page runs in an isolated web view that is discarded after login. Only Spotify’s session cookie is retained in macOS Keychain and sent back to Spotify. Track metadata is sent to LRCLIB for other players and when Spotify has no synchronized lyrics. Any Spotify lyric-text comparison stays on this Mac. Realtime Karaoke uses lyric timestamps locally and does not record system audio.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.7))
    }

    private func menuBarLaneControls(
        _ title: String,
        layout: Binding<MenuBarLyricsLayout>,
        value: Binding<Double>
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 34, alignment: .leading)

            Picker("\(title) layout", selection: layout) {
                ForEach(MenuBarLyricsLayout.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)

            Slider(value: value, in: 120...1_200, step: 20)
                .disabled(layout.wrappedValue == .automatic)

            Text("\(Int(value.wrappedValue)) pt")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

private enum PanelLayout {
    static let width: CGFloat = 540
    static let height: CGFloat = 520
    static let railWidth: CGFloat = 188
}
