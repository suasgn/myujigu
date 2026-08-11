import AppKit
import ApplicationServices
import Combine
import QuartzCore
import MyujiguCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private enum UpdateCadence {
        static let menuBarLayout: TimeInterval = 2.0
    }

    // The real status item stays square and acts only as a stable popover
    // anchor. Two non-activating panels render the camera-safe lyric lanes.
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var popover: NSPopover?
    private let leftMarqueeView = MarqueeStatusView()
    private let rightMarqueeView = MarqueeStatusView()
    private var leftStripPanel: NSPanel!
    private var rightStripPanel: NSPanel!
    private var model: AppModel!
    private var cancellables = Set<AnyCancellable>()
    private var layoutTimer: Timer?
    private var lastStatusItemFrame = NSRect.zero
    private var lastMenuExtraBoundary: CGFloat = 0
    private var lastMenuOwnerPID: pid_t = 0
    private var lastApplicationMenuRightEdge: CGFloat?
    private var lastMenuMeasurementUptime = 0.0
    private var lastNotchReservedRange: ClosedRange<CGFloat>?
    private var alcoveApplication: NSRunningApplication?
    private var leftStripFrame = NSRect.zero
    private var rightStripFrame = NSRect.zero
    private var didRequestAccessibility = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        statusItem.isVisible = true
        model = AppModel()
        leftStripPanel = makeLyricStripPanel(for: leftMarqueeView)
        rightStripPanel = makeLyricStripPanel(for: rightMarqueeView)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
            button.title = ""
            button.image = NSImage(
                systemSymbolName: "music.note",
                accessibilityDescription: "Myujigu"
            )
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.toolTip = "Myujigu"
            button.setAccessibilityLabel("Myujigu")
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Alcove is intentionally detected once. Repeatedly resolving every
        // running application's bundle identifier is surprisingly expensive.
        refreshAlcoveApplication()

        model.$menuBarText
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                self.leftMarqueeView.text = text
                self.rightMarqueeView.text = text
                self.statusItem.button?.toolTip = text
            }
            .store(in: &cancellables)

        model.$lyrics
            .combineLatest(model.$playerState)
            .receive(on: RunLoop.main)
            .sink { [weak self] lyrics, state in
                guard let self else { return }
                for view in [self.leftMarqueeView, self.rightMarqueeView] {
                    view.updateTimeline(
                        lyrics: lyrics,
                        trackID: state.trackID,
                        title: state.title,
                        artist: state.artist,
                        positionMs: state.positionMs,
                        isPlaying: state.status == .playing
                    )
                }
            }
            .store(in: &cancellables)

        layoutTimer = Timer(
            timeInterval: UpdateCadence.menuBarLayout,
            target: self,
            selector: #selector(pollMenuBarLayout(_:)),
            userInfo: nil,
            repeats: true
        )
        if let layoutTimer {
            layoutTimer.tolerance = UpdateCadence.menuBarLayout * 0.2
            RunLoop.main.add(layoutTimer, forMode: .common)
        }

        model.start()

        // Wait until AppKit has attached the status item to its window before
        // calculating the lyric lanes. The popover stays closed until the
        // user clicks the music-note status item.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.refreshMenuBarState()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        layoutTimer?.invalidate()
        popover?.close()
        popover = nil
        leftStripPanel.orderOut(nil)
        rightStripPanel.orderOut(nil)
        model.stop()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshMenuBarState(force: true)
        }
    }

    private func refreshAlcoveApplication() {
        alcoveApplication = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.henrikruscon.Alcove" && !$0.isTerminated
        }
    }

    @objc private func pollMenuBarLayout(_ timer: Timer) {
        refreshMenuBarState()
    }

    private func refreshMenuBarState(force: Bool = false) {
        syncMenuBarAppearance()
        updateMenuBarLayout(force: force)
        updateLyricStripVisibility()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover(retryCount: Int = 0) {
        guard popover?.isShown != true, let button = statusItem.button else { return }
        guard button.window != nil else {
            if retryCount < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.showPopover(retryCount: retryCount + 1)
                }
            }
            return
        }
        let popover = makePopover()
        self.popover = popover
        // The square item never changes with lyric or layout updates, so the
        // popup anchor remains stable.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: LyricsPopoverView(model: model)
        )
        return popover
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              closedPopover === popover
        else {
            return
        }
        // The popover is used infrequently. Releasing its SwiftUI view tree
        // returns the bulk of those allocations while the menu-bar app idles.
        popover = nil
    }

    private func makeLyricStripPanel(for view: MarqueeStatusView) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]

        view.showsNote = false
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        view.prepareForDisplay()
        return panel
    }

    private func updateMenuBarLayout(force: Bool = false) {
        guard
            let window = statusItem.button?.window,
            let screen = window.screen ?? NSScreen.main
        else {
            return
        }

        let menuOwner = NSWorkspace.shared.menuBarOwningApplication
        let menuOwnerPID = menuOwner?.processIdentifier ?? 0
        let now = ProcessInfo.processInfo.systemUptime
        let shouldMeasureApplicationMenu = force
            || menuOwnerPID != lastMenuOwnerPID
            || now - lastMenuMeasurementUptime >= 5
        let applicationMenuRightEdge: CGFloat?
        if shouldMeasureApplicationMenu {
            applicationMenuRightEdge = menuOwner.flatMap(applicationMenuRightEdge(for:))
            lastMenuMeasurementUptime = now
        } else {
            applicationMenuRightEdge = lastApplicationMenuRightEdge
        }
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let menuExtraBoundary = leftmostMenuExtraBoundary(
            on: screen,
            relativeTo: window,
            windowInfo: windowInfo
        )
        let notchReservedRange = alcoveReservedRange(
            on: screen,
            relativeTo: window,
            windowInfo: windowInfo
        )
        let menuEdgeChanged = abs(
            (applicationMenuRightEdge ?? -1) - (lastApplicationMenuRightEdge ?? -1)
        ) >= 1
        let menuExtraBoundaryChanged = abs(menuExtraBoundary - lastMenuExtraBoundary) >= 1
        let notchRangeChanged = abs(
            (notchReservedRange?.lowerBound ?? -1)
                - (lastNotchReservedRange?.lowerBound ?? -1)
        ) >= 1 || abs(
            (notchReservedRange?.upperBound ?? -1)
                - (lastNotchReservedRange?.upperBound ?? -1)
        ) >= 1

        guard force
            || !NSEqualRects(window.frame, lastStatusItemFrame)
            || menuOwnerPID != lastMenuOwnerPID
            || menuEdgeChanged
            || menuExtraBoundaryChanged
            || notchRangeChanged
        else {
            return
        }

        lastStatusItemFrame = window.frame
        lastMenuExtraBoundary = menuExtraBoundary
        lastMenuOwnerPID = menuOwnerPID
        lastApplicationMenuRightEdge = applicationMenuRightEdge
        lastNotchReservedRange = notchReservedRange

        let menuBarY = window.frame.minY
        let menuBarHeight = window.frame.height

        if let cameraSafeRightArea = screen.auxiliaryTopRightArea,
           let cameraSafeLeftArea = screen.auxiliaryTopLeftArea,
           !cameraSafeRightArea.isEmpty,
           !cameraSafeLeftArea.isEmpty {
            let notchLeftEdge = notchReservedRange?.lowerBound
                ?? cameraSafeLeftArea.maxX
            let notchRightEdge = notchReservedRange?.upperBound
                ?? cameraSafeRightArea.minX
            rightStripFrame = stripFrame(
                left: notchRightEdge + 8,
                right: menuExtraBoundary - 4,
                y: menuBarY,
                height: menuBarHeight
            )

            if let applicationMenuRightEdge {
                leftStripFrame = stripFrame(
                    left: max(applicationMenuRightEdge + 8, cameraSafeLeftArea.minX + 8),
                    right: notchLeftEdge - 8,
                    y: menuBarY,
                    height: menuBarHeight
                )
            } else {
                // Without Accessibility there is no safe public way to find
                // where another app's File/Edit/View menus end.
                leftStripFrame = .zero
            }
        } else {
            leftStripFrame = .zero
            rightStripFrame = stripFrame(
                left: screen.frame.midX + 8,
                right: menuExtraBoundary - 4,
                y: menuBarY,
                height: menuBarHeight
            )
        }

        apply(frame: leftStripFrame, to: leftStripPanel, view: leftMarqueeView)
        apply(frame: rightStripFrame, to: rightStripPanel, view: rightMarqueeView)

        let combinedWidth = leftStripFrame.width + rightStripFrame.width
        leftMarqueeView.setVirtualViewport(originX: 0, totalWidth: combinedWidth)
        rightMarqueeView.setVirtualViewport(
            originX: leftStripFrame.width,
            totalWidth: combinedWidth
        )
    }

    private func stripFrame(
        left: CGFloat,
        right: CGFloat,
        y: CGFloat,
        height: CGFloat
    ) -> NSRect {
        let width = floor(right - left)
        guard width >= 48 else { return .zero }
        return NSRect(x: left, y: y, width: width, height: height)
    }

    private func apply(frame: NSRect, to panel: NSPanel, view: MarqueeStatusView) {
        guard !frame.isEmpty else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(frame, display: true)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.updateLayerLayout()
    }

    private func syncMenuBarAppearance() {
        guard let appearance = statusItem.button?.effectiveAppearance else { return }
        for (panel, view) in [
            (leftStripPanel, leftMarqueeView),
            (rightStripPanel, rightMarqueeView),
        ] {
            guard view.appearance?.name != appearance.name else { continue }
            panel?.appearance = appearance
            view.appearance = appearance
            view.needsDisplay = true
        }
    }

    private func updateLyricStripVisibility() {
        let menuBarIsVisible = statusItem.button?.window?.isVisible == true
            && NSMenu.menuBarVisible()
        for (panel, frame) in [
            (leftStripPanel, leftStripFrame),
            (rightStripPanel, rightStripFrame),
        ] {
            let shouldShow = menuBarIsVisible && !frame.isEmpty
            if shouldShow, panel?.isVisible == false {
                panel?.orderFrontRegardless()
            } else if !shouldShow, panel?.isVisible == true {
                panel?.orderOut(nil)
            }
        }
    }

    private func applicationMenuRightEdge(for application: NSRunningApplication) -> CGFloat? {
        guard AXIsProcessTrusted() else {
            if !didRequestAccessibility {
                didRequestAccessibility = true
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            }
            return nil
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXMenuBarAttribute as CFString,
            &menuBarValue
        ) == .success,
        let menuBarValue
        else {
            return nil
        }

        let menuBar = menuBarValue as! AXUIElement
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            menuBar,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
        let children = childrenValue as? [AXUIElement]
        else {
            return nil
        }

        return children.compactMap(accessibilityFrame(of:)).map(\.maxX).max()
    }

    private func leftmostMenuExtraBoundary(
        on screen: NSScreen,
        relativeTo statusWindow: NSWindow,
        windowInfo: [[String: Any]]
    ) -> CGFloat {
        guard let ownInfo = windowInfo.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == statusWindow.windowNumber
        }),
        let ownLayer = (ownInfo[kCGWindowLayer as String] as? NSNumber)?.intValue,
        let ownBounds = cgBounds(from: ownInfo)
        else {
            return statusWindow.frame.minX
        }

        let ownWindowNumber = statusWindow.windowNumber
        let safeRightStart = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
        let candidates = windowInfo.compactMap { info -> CGFloat? in
            guard
                (info[kCGWindowNumber as String] as? NSNumber)?.intValue != ownWindowNumber,
                (info[kCGWindowLayer as String] as? NSNumber)?.intValue == ownLayer,
                let bounds = cgBounds(from: info),
                abs(bounds.minY - ownBounds.minY) < 2,
                abs(bounds.height - ownBounds.height) < 3,
                bounds.width >= 8,
                bounds.width <= 420,
                bounds.minX >= safeRightStart,
                bounds.maxX <= screen.frame.maxX + 1
            else {
                return nil
            }
            return bounds.minX
        }

        // A new status item can be inserted to the left of ours without
        // moving our window. Capping the lane at the earliest real menu extra
        // guarantees that the lyric never paints over it.
        return min(statusWindow.frame.minX, candidates.min() ?? statusWindow.frame.minX)
    }

    private func alcoveReservedRange(
        on screen: NSScreen,
        relativeTo statusWindow: NSWindow,
        windowInfo: [[String: Any]]
    ) -> ClosedRange<CGFloat>? {
        guard
            let safeLeftArea = screen.auxiliaryTopLeftArea,
            let safeRightArea = screen.auxiliaryTopRightArea,
            !safeLeftArea.isEmpty,
            !safeRightArea.isEmpty,
            let alcove = alcoveApplication,
            !alcove.isTerminated
        else {
            return nil
        }

        let fallbackPadding: CGFloat = 24
        let fallbackRange = (safeLeftArea.maxX - fallbackPadding)
            ... (safeRightArea.minX + fallbackPadding)

        guard
            let ownInfo = windowInfo.first(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.intValue
                    == statusWindow.windowNumber
            }),
            let ownBounds = cgBounds(from: ownInfo)
        else {
            return fallbackRange
        }

        let centerX = screen.frame.midX
        let alcoveFrames = windowInfo.compactMap { info -> CGRect? in
            guard
                (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == alcove.processIdentifier,
                let bounds = cgBounds(from: info),
                bounds.width >= 80,
                bounds.width <= screen.frame.width * 0.6,
                bounds.height >= 20,
                bounds.height <= 180,
                abs(bounds.midX - centerX) <= screen.frame.width * 0.25,
                bounds.minY <= ownBounds.minY + 96,
                bounds.maxY >= ownBounds.minY,
                bounds.minX < safeRightArea.minX + 240,
                bounds.maxX > safeLeftArea.maxX - 240
            else {
                return nil
            }
            return bounds
        }

        guard let firstFrame = alcoveFrames.first else {
            // Alcove can opt out of screen capture/window enumeration. Its
            // running process still gets a conservative expanded notch gap.
            return fallbackRange
        }

        let union = alcoveFrames.dropFirst().reduce(firstFrame) { $0.union($1) }
        return min(safeLeftArea.maxX, union.minX)
            ... max(safeRightArea.minX, union.maxX)
    }

    private func cgBounds(from windowInfo: [String: Any]) -> CGRect? {
        guard let dictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    private func accessibilityFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }
}

/// Renders each lyric once, then lets Core Animation move the cached layers at
/// the display refresh rate. This stays smooth without waking Swift/AppKit for
/// every frame or repeatedly shaping the same text.
@MainActor
private final class MarqueeStatusView: NSView {
    private struct TimelineSegment {
        let text: String
        let startTimeMs: Int
        let endTimeMs: Int
        let x: CGFloat
        let width: CGFloat
    }

    var showsNote = true {
        didSet {
            configureTextLayers()
            updateLayerLayout()
            rebuildMotionAnimation()
        }
    }

    var text: String = "Myujigu" {
        didSet {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text != normalized {
                text = normalized
                return
            }
            cachedTextSize = nil
            configureFallbackLayers()
            if timelineSegments.isEmpty {
                rebuildMotionAnimation()
            }
        }
    }

    private let textFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let noteFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private let pointsPerSecond: CGFloat = 30
    private let repeatGap: CGFloat = 20
    private let timelineStartFraction: CGFloat = 0.5
    private let clipLayer = CALayer()
    private let movingLayer = CALayer()
    private let noteLayer = CATextLayer()
    private let firstFallbackLayer = CATextLayer()
    private let repeatedFallbackLayer = CATextLayer()
    private var titleIntroLayer: CATextLayer?
    private var timelineTextLayers: [CATextLayer] = []
    private var timelineTrackID: String?
    private var timelineTitle = ""
    private var timelineArtist = ""
    private var timelineLyrics: Lyrics?
    private var timelineSegments: [TimelineSegment] = []
    private var timelinePositionMs: Double = 0
    private var timelineIsPlaying = false
    private var animationAnchorPositionMs: Double = 0
    private var animationAnchorMediaTime = CACurrentMediaTime()
    private var virtualViewportOriginX: CGFloat = 0
    private var virtualViewportWidth: CGFloat = 0
    private var cachedTextSize: NSSize?
    private var isLayerTreePrepared = false
    private weak var preparedRootLayer: CALayer?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Mouse events continue through to the NSStatusBarButton.
        nil
    }

    override func layout() {
        super.layout()
        updateLayerLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        prepareForDisplay()
        updateContentsScale()
        DispatchQueue.main.async { [weak self] in
            self?.prepareForDisplay()
            self?.updateLayerLayout()
            self?.rebuildMotionAnimation()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        configureTextLayers()
    }

    func prepareForDisplay() {
        guard let rootLayer = layer, preparedRootLayer !== rootLayer else { return }
        preparedRootLayer = rootLayer
        isLayerTreePrepared = true

        withoutImplicitAnimations {
            rootLayer.masksToBounds = true
            clipLayer.masksToBounds = true
            movingLayer.anchorPoint = .zero
            movingLayer.position = .zero
            clipLayer.addSublayer(movingLayer)
            rootLayer.addSublayer(clipLayer)
            rootLayer.addSublayer(noteLayer)
            movingLayer.addSublayer(firstFallbackLayer)
            movingLayer.addSublayer(repeatedFallbackLayer)
        }
        configureTextLayers()
        rebuildTimelineLayers()
        updateLayerLayout()
        rebuildMotionAnimation()
    }

    func updateLayerLayout() {
        if preparedRootLayer !== layer {
            prepareForDisplay()
        }
        guard isLayerTreePrepared else { return }
        let textHeight = ceil(textLineHeight)
        let textY = floor((bounds.height - textHeight) / 2)
        let noteSize = ("♪" as NSString).size(withAttributes: noteAttributes)

        withoutImplicitAnimations {
            clipLayer.frame = CGRect(
                x: textOriginX,
                y: 0,
                width: max(bounds.width - textOriginX - 8, 0),
                height: bounds.height
            )
            movingLayer.bounds = CGRect(
                x: 0,
                y: 0,
                width: max(timelineSegments.last.map { $0.x + $0.width } ?? textSize.width, 1),
                height: bounds.height
            )
            movingLayer.position = .zero

            noteLayer.frame = CGRect(
                x: 7,
                y: floor((bounds.height - noteSize.height) / 2),
                width: ceil(noteSize.width),
                height: ceil(noteSize.height)
            )
            firstFallbackLayer.frame = CGRect(
                x: 0,
                y: textY,
                width: ceil(textSize.width),
                height: textHeight
            )
            repeatedFallbackLayer.frame = CGRect(
                x: ceil(textSize.width) + repeatGap,
                y: textY,
                width: ceil(textSize.width),
                height: textHeight
            )
            if let titleIntroLayer {
                let introWidth = ceil(titleIntroSize.width)
                titleIntroLayer.frame = CGRect(
                    x: -introWidth,
                    y: textY,
                    width: introWidth,
                    height: textHeight
                )
            }

            for (segment, textLayer) in zip(timelineSegments, timelineTextLayers) {
                textLayer.frame = CGRect(
                    x: segment.x,
                    y: textY,
                    width: ceil(segment.width),
                    height: textHeight
                )
            }
        }
    }

    func setVirtualViewport(originX: CGFloat, totalWidth: CGFloat) {
        guard virtualViewportOriginX != originX || virtualViewportWidth != totalWidth else {
            return
        }
        virtualViewportOriginX = originX
        virtualViewportWidth = totalWidth
        rebuildMotionAnimation()
    }

    func updateTimeline(
        lyrics: Lyrics?,
        trackID: String?,
        title: String,
        artist: String,
        positionMs: Int,
        isPlaying: Bool
    ) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldRebuild = timelineTrackID != trackID
            || timelineLyrics != lyrics
            || timelineTitle != normalizedTitle
            || timelineArtist != normalizedArtist
        let wasPlaying = timelineIsPlaying
        let now = CACurrentMediaTime()
        let expectedPositionMs = animationAnchorPositionMs
            + (wasPlaying ? (now - animationAnchorMediaTime) * 1_000 : 0)
        timelinePositionMs = Double(positionMs)
        timelineIsPlaying = isPlaying

        if shouldRebuild {
            timelineTrackID = trackID
            timelineTitle = normalizedTitle
            timelineArtist = normalizedArtist
            timelineLyrics = lyrics
            buildTimeline(from: lyrics)
            rebuildTimelineLayers()
            updateLayerLayout()
            rebuildMotionAnimation()
        } else if !timelineSegments.isEmpty {
            let playbackChanged = wasPlaying != isPlaying
            let positionDrifted = abs(expectedPositionMs - timelinePositionMs) >= 150
            if playbackChanged || positionDrifted {
                rebuildMotionAnimation()
            }
        }
    }

    private var textOriginX: CGFloat { showsNote ? 27 : 8 }

    private var effectiveViewportWidth: CGFloat {
        max(virtualViewportWidth, bounds.width)
    }

    private var availableTextWidth: CGFloat {
        max(effectiveViewportWidth - textOriginX - 8, 0)
    }

    private var displayedText: String {
        text
    }

    private var titleIntroText: String {
        let metadata = [timelineTitle, timelineArtist]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        return metadata.isEmpty ? "" : metadata + "   •   "
    }

    private var titleIntroSize: NSSize {
        (titleIntroText as NSString).size(withAttributes: textAttributes)
    }

    private var titleIntroHoldTimeMs: Int {
        guard !titleIntroText.isEmpty,
              let first = timelineSegments.first,
              first.startTimeMs > 0
        else {
            return 0
        }

        // Let the metadata register at the right edge before the lyric strip
        // moves. Reserve most of a short intro for the actual travel so the
        // first lyric can still arrive at the center on its sync timestamp.
        return min(1_500, first.startTimeMs / 3)
    }

    private var noteAttributes: [NSAttributedString.Key: Any] {
        [.font: noteFont, .foregroundColor: NSColor.labelColor]
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: textFont, .foregroundColor: NSColor.labelColor]
    }

    private var textSize: NSSize {
        if let cachedTextSize {
            return cachedTextSize
        }
        let size = (displayedText as NSString).size(withAttributes: textAttributes)
        cachedTextSize = size
        return size
    }

    private var textLineHeight: CGFloat {
        ("Ag" as NSString).size(withAttributes: textAttributes).height
    }

    private func configureTextLayers() {
        guard isLayerTreePrepared else { return }
        configure(noteLayer, text: "♪", attributes: noteAttributes)
        noteLayer.isHidden = !showsNote
        configureFallbackLayers()
        if let titleIntroLayer {
            configure(titleIntroLayer, text: titleIntroText, attributes: textAttributes)
        }
        for (segment, textLayer) in zip(timelineSegments, timelineTextLayers) {
            configure(textLayer, text: segment.text, attributes: textAttributes)
        }
    }

    private func configureFallbackLayers() {
        guard isLayerTreePrepared else { return }
        let attributes = textAttributes
        configure(firstFallbackLayer, text: displayedText, attributes: attributes)
        configure(repeatedFallbackLayer, text: displayedText, attributes: attributes)
        updateLayerLayout()
    }

    private func configure(
        _ textLayer: CATextLayer,
        text: String,
        attributes: [NSAttributedString.Key: Any]
    ) {
        withoutImplicitAnimations {
            let font = attributes[.font] as? NSFont ?? textFont
            let color = attributes[.foregroundColor] as? NSColor ?? .labelColor
            textLayer.string = text
            textLayer.font = font.fontName as CFTypeRef
            textLayer.fontSize = font.pointSize
            textLayer.foregroundColor = color.cgColor
            textLayer.alignmentMode = .left
            textLayer.isWrapped = false
            textLayer.truncationMode = .none
            textLayer.contentsScale = contentsScale
        }
    }

    private var contentsScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func updateContentsScale() {
        guard isLayerTreePrepared else { return }
        var textLayers = [noteLayer, firstFallbackLayer, repeatedFallbackLayer]
        if let titleIntroLayer {
            textLayers.append(titleIntroLayer)
        }
        textLayers.append(contentsOf: timelineTextLayers)
        for textLayer in textLayers {
            textLayer.contentsScale = contentsScale
        }
    }

    private func buildTimeline(from lyrics: Lyrics?) {
        guard let lyrics, lyrics.syncType.uppercased() != "UNSYNCED" else {
            timelineSegments = []
            return
        }

        let usableLines = lyrics.lines.filter {
            !$0.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var cursor: CGFloat = 0
        timelineSegments = usableLines.enumerated().map { index, line in
            let suffix = index + 1 < usableLines.count ? "   •   " : ""
            let value = line.words + suffix
            let width = (value as NSString).size(withAttributes: textAttributes).width
            defer { cursor += width }
            return TimelineSegment(
                text: value,
                startTimeMs: line.startTimeMs,
                endTimeMs: line.endTimeMs,
                x: cursor,
                width: width
            )
        }
    }

    private func rebuildTimelineLayers() {
        guard isLayerTreePrepared else { return }
        titleIntroLayer?.removeFromSuperlayer()
        titleIntroLayer = nil
        timelineTextLayers.forEach { $0.removeFromSuperlayer() }
        timelineTextLayers = timelineSegments.map { segment in
            let textLayer = CATextLayer()
            configure(textLayer, text: segment.text, attributes: textAttributes)
            movingLayer.addSublayer(textLayer)
            return textLayer
        }

        if !timelineSegments.isEmpty, !titleIntroText.isEmpty {
            let textLayer = CATextLayer()
            configure(textLayer, text: titleIntroText, attributes: textAttributes)
            movingLayer.addSublayer(textLayer)
            titleIntroLayer = textLayer
        }

        let hasTimeline = !timelineTextLayers.isEmpty
        firstFallbackLayer.isHidden = hasTimeline
        repeatedFallbackLayer.isHidden = hasTimeline
        updateContentsScale()
    }

    private func rebuildMotionAnimation() {
        guard isLayerTreePrepared else { return }
        movingLayer.removeAnimation(forKey: "lyricMotion")

        if !timelineSegments.isEmpty {
            installTimelineAnimation()
        } else {
            installFallbackAnimation()
        }
    }

    private func installTimelineAnimation() {
        guard let lastSegment = timelineSegments.last else { return }
        let lyricEndTimeMs = max(lastSegment.endTimeMs, 1)
        // Keep the animation alive at its final, fully-offscreen value until
        // the track changes. Ending the CA animation at the last lyric allowed
        // its presentation timeline to return to the first keyframe during a
        // long outro on some systems.
        let terminalHoldTimeMs = lyricEndTimeMs + 6 * 60 * 60 * 1_000
        var times = [0]
        var values = [timelineTranslation(at: 0)]

        let introHoldTimeMs = titleIntroHoldTimeMs
        if introHoldTimeMs > 0 {
            times.append(introHoldTimeMs)
            values.append(timelineTranslation(at: Double(introHoldTimeMs)))
        }

        for segment in timelineSegments where segment.startTimeMs > times.last! {
            times.append(segment.startTimeMs)
            values.append(timelineTranslation(at: Double(segment.startTimeMs)))
        }
        if lyricEndTimeMs > times.last! {
            times.append(lyricEndTimeMs)
            values.append(timelineTranslation(at: Double(lyricEndTimeMs)))
        }
        times.append(terminalHoldTimeMs)
        values.append(values.last ?? timelineTranslation(at: Double(lyricEndTimeMs)))

        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = values.map { NSNumber(value: Double($0)) }
        animation.keyTimes = times.map {
            NSNumber(value: Double($0) / Double(terminalHoldTimeMs))
        }
        animation.duration = Double(terminalHoldTimeMs) / 1_000
        animation.calculationMode = .linear
        animation.repeatCount = 0
        animation.autoreverses = false
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        let mediaTime = CACurrentMediaTime()
        let positionSeconds = min(
            max(timelinePositionMs / 1_000, 0),
            animation.duration
        )
        animation.beginTime = movingLayer.convertTime(mediaTime, from: nil)
        animation.timeOffset = positionSeconds
        animation.speed = timelineIsPlaying ? 1 : 0

        withoutImplicitAnimations {
            movingLayer.setAffineTransform(
                CGAffineTransform(translationX: values.last ?? 0, y: 0)
            )
        }
        movingLayer.add(animation, forKey: "lyricMotion")
        animationAnchorPositionMs = positionSeconds * 1_000
        animationAnchorMediaTime = mediaTime
    }

    private func installFallbackAnimation() {
        resetLayerClock()
        let start = -virtualViewportOriginX
        guard textSize.width > availableTextWidth else {
            repeatedFallbackLayer.isHidden = true
            withoutImplicitAnimations {
                movingLayer.setAffineTransform(CGAffineTransform(translationX: start, y: 0))
            }
            return
        }

        repeatedFallbackLayer.isHidden = false
        let cycle = textSize.width + repeatGap
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = start
        animation.toValue = start - cycle
        animation.duration = Double(cycle / pointsPerSecond)
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)

        withoutImplicitAnimations {
            movingLayer.setAffineTransform(CGAffineTransform(translationX: start, y: 0))
        }
        movingLayer.add(animation, forKey: "lyricMotion")
    }

    private func resetLayerClock() {
        withoutImplicitAnimations {
            movingLayer.speed = 1
            movingLayer.timeOffset = 0
            movingLayer.beginTime = 0
        }
    }

    private func timelineTranslation(at positionMs: Double) -> CGFloat {
        -timelineOffset(at: positionMs, viewportWidth: effectiveViewportWidth)
            - virtualViewportOriginX
    }

    private func timelineOffset(at positionMs: Double, viewportWidth: CGFloat) -> CGFloat {
        guard let first = timelineSegments.first else { return 0 }
        let firstAnchorOffset = timelineAnchorOffset(for: first, viewportWidth: viewportWidth)
        guard positionMs >= Double(first.startTimeMs) else {
            // Present the title and artist at the right edge first. After the
            // short hold, move the whole strip so the first lyric still
            // arrives at the center exactly on its sync timestamp.
            let rightEdgeOffset = textOriginX + first.x - viewportWidth
            let holdTimeMs = Double(titleIntroHoldTimeMs)
            guard positionMs > holdTimeMs else { return rightEdgeOffset }
            let duration = max(Double(first.startTimeMs) - holdTimeMs, 1)
            let progress = min(max((positionMs - holdTimeMs) / duration, 0), 1)
            return rightEdgeOffset
                + (firstAnchorOffset - rightEdgeOffset) * CGFloat(progress)
        }

        var low = 0
        var high = timelineSegments.count
        while low < high {
            let middle = (low + high) / 2
            if Double(timelineSegments[middle].startTimeMs) <= positionMs {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = max(0, low - 1)
        let segment = timelineSegments[index]
        let segmentAnchorOffset = timelineAnchorOffset(for: segment, viewportWidth: viewportWidth)

        if index + 1 < timelineSegments.count {
            let next = timelineSegments[index + 1]
            let duration = max(Double(next.startTimeMs - segment.startTimeMs), 1)
            let progress = min(max((positionMs - Double(segment.startTimeMs)) / duration, 0), 1)
            let nextAnchorOffset = timelineAnchorOffset(for: next, viewportWidth: viewportWidth)
            return segmentAnchorOffset
                + (nextAnchorOffset - segmentAnchorOffset) * CGFloat(progress)
        }

        let duration = max(Double(segment.endTimeMs - segment.startTimeMs), 1)
        let progress = min(max((positionMs - Double(segment.startTimeMs)) / duration, 0), 1)
        let startX = timelineStartX(viewportWidth: viewportWidth)
        // Keep the final line moving until its last character has crossed the
        // left clipping edge instead of stopping while it is still visible.
        let finalTravel = max(startX + segment.width - textOriginX, 0)
        return segmentAnchorOffset + finalTravel * CGFloat(progress)
    }

    private func timelineAnchorOffset(
        for segment: TimelineSegment,
        viewportWidth: CGFloat
    ) -> CGFloat {
        textOriginX + segment.x - timelineStartX(viewportWidth: viewportWidth)
    }

    private func timelineStartX(viewportWidth: CGFloat) -> CGFloat {
        max(textOriginX, viewportWidth * timelineStartFraction)
    }

    private func withoutImplicitAnimations(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
