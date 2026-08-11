import AppKit
import MyujiguCore
import SwiftUI

struct LyricsPopoverView: View {
    @ObservedObject var model: AppModel
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            controls
        }
        .frame(width: 420, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.playerState.title.isEmpty ? "Myujigu" : model.playerState.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(model.playerState.artist.isEmpty ? model.playbackDescription : model.playerState.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.playerState.status == .playing ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if let lyrics = model.lyrics {
            LyricsScrollView(
                lyrics: lyrics,
                activeIndex: model.activeLineIndex,
                positionMs: model.playerState.positionMs
            )
        } else {
            VStack(spacing: 12) {
                Spacer()
                if model.isLoadingLyrics {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading synced lyrics…")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: model.playerState.trackID == nil ? "music.note" : "text.quote")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text(emptyMessage)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 290)
                    if model.playerState.trackID != nil {
                        Button("Try Again") { model.reloadLyrics() }
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        HStack(spacing: 22) {
            Button { model.send(.previous) } label: {
                Image(systemName: "backward.fill")
            }
            Button { model.send(.playPause) } label: {
                Image(systemName: model.playerState.status == .playing ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 26, height: 26)
            }
            Button { model.send(.next) } label: {
                Image(systemName: "forward.fill")
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var statusText: String {
        var parts = [model.playbackDescription]
        if let source = model.lyricsSource {
            parts.append(source.rawValue)
        }
        if let syncType = model.lyrics?.syncType.lowercased() {
            parts.append(syncType)
        }
        return parts.joined(separator: " · ")
    }

    private var emptyMessage: String {
        if model.playerState.status == .unavailable {
            let playerName = model.playerState.player == .appleMusic ? "Music" : "Spotify"
            return "Open \(playerName) and allow Myujigu to control it in System Settings → Privacy & Security → Automation."
        }
        if model.playerState.trackID == nil {
            return "Play a song in Spotify or Music."
        }
        return model.lyricsError ?? "No lyrics found."
    }
}

private struct LyricsScrollView: View {
    let lyrics: Lyrics
    let activeIndex: Int?
    let positionMs: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                    LyricLineView(
                        line: line,
                        isActive: index == activeIndex,
                        hasPassed: index < (activeIndex ?? 0),
                        positionMs: positionMs
                    )
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
    }
}

private struct LyricLineView: View {
    let line: LyricLine
    let isActive: Bool
    let hasPassed: Bool
    let positionMs: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(formatTime(line.startTimeMs))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
            karaokeText
                .font(isActive ? .title3.weight(.bold) : .body.weight(.medium))
                .opacity(isActive ? 1 : (hasPassed ? 0.35 : 0.58))
                .animation(.easeInOut(duration: 0.2), value: isActive)
        }
    }

    private var karaokeText: Text {
        guard isActive, !line.syllables.isEmpty else {
            return Text(line.words)
        }

        let completed = line.syllables
            .prefix(while: { $0.startTimeMs <= positionMs })
            .reduce(0) { $0 + $1.count }
        let characters = Array(line.words)
        let split = min(max(completed, 0), characters.count)
        return Text(String(characters[..<split])).foregroundColor(.green)
            + Text(String(characters[split...])).foregroundColor(.primary)
    }

    private func formatTime(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingSpotifyLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Spotify connection")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("Cached lyrics work without a login. Sign in with Spotify to load songs that are not yet cached by Spotify Desktop.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(model.hasCredential ? "Sign In Again" : "Sign In with Spotify") {
                    showingSpotifyLogin = true
                }
                .buttonStyle(.borderedProminent)
                Button("Remove Login", role: .destructive) {
                    model.saveCredential("")
                }
                .disabled(!model.hasCredential)
                Spacer()
            }

            if let message = model.settingsMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("The sign-in page runs in a temporary, isolated web view. Myujigu reads only Spotify's sp_dc session cookie, stores it in your macOS Keychain, and discards the web view after sign-in.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("The saved login is sent only to Spotify endpoints. It can expire; sign in again if authentication stops working.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(22)
        .frame(width: 430, height: 330)
        .sheet(isPresented: $showingSpotifyLogin) {
            SpotifyLoginView { cookie in
                model.saveCredential(cookie)
            }
        }
    }
}
