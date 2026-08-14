import Foundation
import MyujiguCore

enum RealtimeKaraokeStatus: Equatable {
    case disabled
    case waitingForLyrics
    case paused
    case followingTiming(estimated: Bool)

    var message: String {
        switch self {
        case .disabled:
            return "Off"
        case .waitingForLyrics:
            return "Waiting for synchronized lyrics."
        case .paused:
            return "Ready — playback is paused."
        case .followingTiming(let estimated):
            return estimated
                ? "Estimating words from synchronized line timing"
                : "Following provider word timing"
        }
    }

    var isFollowingTiming: Bool {
        if case .followingTiming = self { return true }
        return false
    }
}

@MainActor
final class RealtimeKaraokeController {
    struct PlaybackContext {
        let enabled: Bool
        let trackID: String?
        let isPlaying: Bool
        let positionMs: Int
        let lyrics: Lyrics?
        let activeLineIndex: Int?
    }

    private let statusHandler: (RealtimeKaraokeStatus) -> Void
    private let highlightHandler: (LiveWordHighlight?) -> Void
    private var context = PlaybackContext(
        enabled: false,
        trackID: nil,
        isPlaying: false,
        positionMs: 0,
        lyrics: nil,
        activeLineIndex: nil
    )
    private var timeline: KaraokeWordTimeline?
    private var timelineLyrics: Lyrics?
    private var schedulerTask: Task<Void, Never>?
    private var anchorPositionMs = 0.0
    private var anchorUptime = ProcessInfo.processInfo.systemUptime
    private var displayedHighlight: LiveWordHighlight?

    init(
        statusHandler: @escaping (RealtimeKaraokeStatus) -> Void,
        highlightHandler: @escaping (LiveWordHighlight?) -> Void
    ) {
        self.statusHandler = statusHandler
        self.highlightHandler = highlightHandler
    }

    func update(_ newContext: PlaybackContext) {
        context = newContext
        anchorPositionMs = Double(newContext.positionMs)
        anchorUptime = ProcessInfo.processInfo.systemUptime

        if timelineLyrics != newContext.lyrics {
            timelineLyrics = newContext.lyrics
            timeline = newContext.lyrics.map(KaraokeWordTimeline.init)
        }

        guard newContext.enabled else {
            stopScheduler()
            setHighlight(nil)
            statusHandler(.disabled)
            return
        }
        guard let lyrics = newContext.lyrics,
              lyrics.syncType.uppercased() != "UNSYNCED",
              timeline?.cues.isEmpty == false
        else {
            stopScheduler()
            setHighlight(nil)
            statusHandler(.waitingForLyrics)
            return
        }
        guard newContext.isPlaying, newContext.trackID != nil else {
            stopScheduler()
            setHighlight(nil)
            statusHandler(.paused)
            return
        }

        statusHandler(.followingTiming(estimated: timeline?.usesProviderWordTiming != true))
        renderCurrentWord()
        startSchedulerIfNeeded()
    }

    func stop() {
        stopScheduler()
        setHighlight(nil)
    }

    private func startSchedulerIfNeeded() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                renderCurrentWord()

                let position = estimatedPositionMs
                let nextTransition = timeline?.nextTransitionTime(after: position)
                let untilTransition = nextTransition.map { max($0 - position, 20) } ?? 250
                let delayMs = min(untilTransition, 250)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func stopScheduler() {
        schedulerTask?.cancel()
        schedulerTask = nil
    }

    private func renderCurrentWord() {
        guard context.enabled, context.isPlaying else { return }
        setHighlight(timeline?.highlight(at: estimatedPositionMs))
    }

    private var estimatedPositionMs: Int {
        let elapsed = ProcessInfo.processInfo.systemUptime - anchorUptime
        return max(Int(anchorPositionMs + elapsed * 1_000), 0)
    }

    private func setHighlight(_ highlight: LiveWordHighlight?) {
        guard displayedHighlight != highlight else { return }
        displayedHighlight = highlight
        highlightHandler(highlight)
    }
}
