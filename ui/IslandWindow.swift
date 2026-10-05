// Island panel (SPEC §4): one fixed transparent NSPanel at the top centre of the target
// screen; the shape animates inside it. Decides per take: target screen (under the mouse),
// notch geometry, Alcove coexistence, fullscreen suppression; runs auto-hide timers and the
// start/stop sounds. Ordered out whenever nothing is shown (0 CPU when idle).
import AppKit
import CoreAudio
import SwiftUI

/// Borderless, non-activating, click-through panel above the menu bar.
final class IslandPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        // NSApp.hide (used when the hub closes without a previous app to return to) must
        // never hide a running take
        canHide = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // the panel deliberately covers the menu bar / notch area
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The panel never becomes key, so the first click on a hovered confirmation (copy button)
/// must reach SwiftUI directly instead of being spent on activating the window.
final class IslandHostingView: NSHostingView<IslandView> {
    required init(rootView: IslandView) {
        super.init(rootView: rootView)
    }

    required init?(coder: NSCoder) {
        fatalError("IslandHostingView is created in code only")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Notch and menu-bar geometry of one screen, measured (never hard-coded).
struct IslandScreenGeometry {
    let frame: CGRect
    let notch: CGSize?
    let notchMidX: CGFloat
    let menuBarHeight: CGFloat
    /// safeAreaInsets.top: the camera-housing band (0 without a notch)
    let safeTop: CGFloat
    let displayID: CGDirectDisplayID?
    let scale: CGFloat

    init(screen: NSScreen) {
        frame = screen.frame
        scale = screen.backingScaleFactor
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let top = screen.safeAreaInsets.top
        safeTop = top
        if top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea,
           frame.width - l.width - r.width > 40 {
            let w = frame.width - l.width - r.width
            notch = CGSize(width: w, height: top)
            notchMidX = frame.minX + l.width + w / 2
        } else {
            notch = nil
            notchMidX = frame.midX
        }
        let gap = frame.maxY - screen.visibleFrame.maxY
        menuBarHeight = gap > 1 ? gap : (notch?.height ?? 24)
    }

    /// panel origin: top edge flush with the screen top, centred on the notch, pixel aligned
    func panelOrigin(for size: CGSize) -> CGPoint {
        let s = max(scale, 1)
        let x = ((notchMidX - size.width / 2) * s).rounded() / s
        return CGPoint(x: x, y: frame.maxY - size.height)
    }
}

@MainActor
final class IslandController {
    static let alcoveBundleID = "com.henrikruscon.Alcove"

    private let state: AppState
    let model = IslandModel()
    private var panel: IslandPanel?
    private let headless = ProcessInfo.processInfo.environment["VOICEBUD_UI_HEADLESS"] == "1"
    private var targetDisplay: CGDirectDisplayID?
    private var lastPhase: Phase = .idle
    private var suppressed = false
    private var hideWork: DispatchWorkItem?
    /// when the running `hideWork` fires (its remaining time is frozen while hovered)
    private var hideDeadline: Date?
    private var orderOutWork: DispatchWorkItem?
    private var presentWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    // Hover on the confirmation (SPEC §0, decided 03.10.)
    /// ~30 Hz pointer polling; exists ONLY while a done card is visible (no global event
    /// monitors, the helper has no permissions; idle CPU stays 0)
    private var hoverTimer: Timer?
    private var pointerInside = false
    /// where the pointer rested when the card appeared: a pointer parked there only counts once
    /// it moves, so a card growing under a resting pointer does not unfold by itself
    private var parkedPointer: NSPoint?
    /// remaining confirmation time, frozen while the pointer is on the card
    private var suspendedHide: Double?
    /// pointer left: 0.6 s grace, then fold back and resume the confirmation timer
    private var collapseWork: DispatchWorkItem?
    /// headless tests only (`_test_pointer`): a headless panel is never on screen
    private var virtualPointerInside = false

    init(state: AppState) {
        self.state = state
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main {
            apply(IslandScreenGeometry(screen: screen))
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                }
            })
        // build the (ordered-out, empty) panel right after launch so the first hotkey press
        // does not pay for SwiftUI's first graph setup
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { _ = self?.ensurePanel() }
        }
    }

    // MARK: Hooks called by the core

    /// Call after every `state` message (state.phase already updated).
    func phaseDidChange() {
        let phase = state.phase
        let previous = lastPhase
        lastPhase = phase
        let endedRecording = previous == .recording && phase != .recording
        if phase != .recording { OutputMute.end() }
        defer { updateHealTimer() }
        if phase != .processing {
            slowWork.forEach { $0.cancel() }
            slowWork = []
            if model.slowSince != nil || model.slowHint { quietly { model.slowSince = nil; model.slowHint = false } }
        } else if previous != .processing && state.mode != .ocr {
            // (Texterkennung: no count and no "⌃⇧ bricht ab", that key starts a dictation; the
            // helper's own 15 s timeout ends a stuck recognition)
            // from 5 s the ear counts the seconds, from 10 s the card says "Dauert länger" (and a
            // hotkey press cancels, see the core)
            let start = Date()
            let count = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.state.phase == .processing else { return }
                    self.update { self.model.slowSince = start }
                }
            }
            let hint = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.state.phase == .processing else { return }
                    self.update { self.model.slowHint = true }
                    // the core cancels only a take the island offers to cancel: the notch card or
                    // the capsule shows "⌃⇧ bricht ab" (live text has no room for it)
                    if self.state.mode != .ocr && (self.model.kind == .capsule || self.model.flavour != .live) {
                        IPC.send(["type": "slow_hint"])
                    }
                }
            }
            slowWork = [count, hint]
            DispatchQueue.main.asyncAfter(deadline: .now() + IslandSlow.count, execute: count)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(IslandSlow.hint, state.hintAfter ?? 0), execute: hint)
        }

        switch phase {
        case .recording:
            // (a dictation started during "Bereich wählen" is a take of its own: new island, sounds, mute)
            if previous == .recording && model.presented && panel?.isVisible == true && model.mode == state.mode { return }
            beginTake(at: .recording)
            if state.mode != .ocr {          // choosing a region for Texterkennung records nothing
                playSound("Tink")
                OutputMute.begin(state.settings)
            }
        case .processing:
            if endedRecording { playSound("Pop") }
            freezeTimer()
            stopHoverTracking()
            hideWork?.cancel()                // a card's timer must not close the spinner after it
            hideWork = nil
            if isShowing {
                update {
                    self.model.hover = .none
                    self.model.mode = self.state.mode
                    self.model.phase = .processing
                }
            } else {
                beginTake(at: .processing)
            }
        case .done:
            if endedRecording { playSound("Pop") }
            freezeTimer()
            guard let info = state.done else { dismiss(quick: true); return }
            stopHoverTracking()
            if isShowing {
                update {
                    self.model.done = info
                    self.model.mode = self.state.mode
                    self.model.hover = .none
                    self.model.phase = .done
                }
            } else {
                beginTake(at: .done)
            }
            scheduleHide(after: confirmDelay)
            startHoverTracking()
        case .empty:
            if endedRecording { playSound("Pop") }
            dismiss(quick: true)
        case .error:
            freezeTimer()
            stopHoverTracking()
            let message = state.errorMessage ?? "Fehler"
            if isShowing {
                let ok = state.noticeOK
                update {
                    self.model.errorMessage = message
                    self.model.noticeOK = ok
                    self.model.hover = .none
                    self.model.phase = .error
                }
            } else {
                beginTake(at: .error)
            }
            scheduleHide(after: 2.5)
        case .idle:
            // a confirmation that is still on its timer (or set to stay, or held by the pointer)
            // finishes on its own
            let confirming = model.phase == .done || model.phase == .error
            if confirming && model.presented && (hideWork != nil || confirmDelay == nil || hoverHolds) { return }
            dismiss(quick: false)
        }
    }

    /// Call after settings changed. Shape, style and position are chosen once per take at
    /// recording start; waveform style/liveness are read live by the view.
    func settingsDidChange() {
        if model.phase == .done, model.presented {
            if state.settings.confirmHoverExpand {
                startHoverTracking()
            } else if hoverTimer != nil {
                // switched off while a confirmation is up: back to the plain timed card
                let holding = hoverHolds
                let remaining = suspendedHide
                stopHoverTracking()
                if model.hover == .expanded { update { self.model.hover = .collapsed } }
                if holding, hideWork == nil, confirmDelay != nil {
                    scheduleHide(after: max(remaining ?? 0, 0.8))
                }
            }
        }
        if model.phase == .done, model.presented, let work = hideWork {
            work.cancel()
            scheduleHide(after: confirmDelay)
        }
    }

    /// Headless tests: moves a virtual pointer onto / off the confirmation card.
    func testPointer(inside: Bool) {
        virtualPointerInside = inside
        pollPointer()
    }

    // MARK: Take lifecycle

    /// really on screen: presented, ordered in and not on its way out (a state that arrives during
    /// a dismiss must start over, not update a surface that is about to be ordered out)
    private var isShowing: Bool {
        model.presented && model.phase != .idle && panel?.isVisible == true && orderOutWork == nil
    }

    /// Self-healing (04.10.): a running recording is always on screen. The panel could be gone
    /// while the core kept recording (ordered out by a dismiss or a screen change), and every
    /// further hotkey press then started or stopped a take nobody saw, until a restart. Called
    /// with every level message (about 30 per second while recording); a gap shorter than 0.4 s
    /// is the normal entry animation.
    private var hiddenSince: Date?
    private var healTimer: Timer?
    private var slowWork: [DispatchWorkItem] = []
    func ensureVisibleWhileRecording() {
        let phase = state.phase
        guard phase == .recording || phase == .processing, !headless, !suppressed else {
            hiddenSince = nil
            return
        }
        if model.presented, model.phase == phase, let panel, panel.isVisible, panel.alphaValue > 0.5,
           orderOutWork == nil, reallyOnScreen(panel) {
            hiddenSince = nil
            return
        }
        let since = hiddenSince ?? Date()
        hiddenSince = since
        guard Date().timeIntervalSince(since) > 0.4 else { return }
        hiddenSince = nil
        if let panel, panel.isVisible, !reallyOnScreen(panel) {
            rebuildPanel("\(phase.rawValue) ordered in but not on screen")
        } else {
            IPC.log("island: \(phase.rawValue) was not on screen, shown again")
        }
        beginTake(at: phase)
    }

    /// what macOS shows, not what AppKit believes: `isVisible` stays true for a panel ordered in
    /// on another Space (04.10.: the panel had lost "all Spaces" and stayed on desktop 1 while
    /// Nils worked on desktop 3; every take faded in and out unseen, a restart fixed it)
    private func reallyOnScreen(_ p: NSWindow) -> Bool {
        guard p.windowNumber > 0 else { return false }
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(p.windowNumber)) as? [[String: Any]]
        return (info?.first?[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    private func orderIn(_ geo: IslandScreenGeometry) {
        let panel = ensurePanel()
        panel.setFrame(CGRect(origin: geo.panelOrigin(for: model.canvas), size: model.canvas), display: false)
        panel.alphaValue = 0
        if !headless && !suppressed { panel.orderFrontRegardless() }
    }

    /// a first ordering in creates the window, which the window server reports some 40 ms later
    private var panelShownBefore = false

    /// a fresh panel joins every Space again; the old one's behaviour goes to the log to find out
    /// what took it away
    private var lastRebuild: Date?
    private func rebuildPanel(_ why: String) {
        lastRebuild = Date()
        IPC.log("island: \(why), behavior \(panel?.collectionBehavior.rawValue ?? 0) level \(panel?.level.rawValue ?? 0), panel rebuilt")
        panel?.orderOut(nil)
        panel = nil
        panelShownBefore = false
    }

    /// shortly after a card or notice appears (those have no heal timer): really on screen?
    private func verifyOnScreen() {
        guard !headless, !suppressed, let panel, panel.isVisible, model.presented, orderOutWork == nil,
              model.phase != .idle, !reallyOnScreen(panel),
              lastRebuild.map({ Date().timeIntervalSince($0) > 5 }) ?? true else { return }
        let phase = model.phase
        rebuildPanel("\(phase.rawValue) ordered in but not on screen")
        beginTake(at: phase)
        switch phase {
        case .done:
            scheduleHide(after: confirmDelay)
            startHoverTracking()
        case .error:
            scheduleHide(after: 2.5)
        default:
            break
        }
    }

    /// The check runs on its own clock while recording or processing (level messages stop when
    /// the core's level loop stops, and processing sends none at all).
    private func updateHealTimer() {
        let needed = state.phase == .recording || state.phase == .processing
        if needed && healTimer == nil {
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.ensureVisibleWhileRecording() }
            }
            RunLoop.main.add(t, forMode: .common)
            healTimer = t
        } else if !needed, let t = healTimer {
            t.invalidate()
            healTimer = nil
            hiddenSince = nil
        }
    }

    private func alcoveShowing(_ geo: IslandScreenGeometry) -> Bool {
        geo.notch != nil && isAlcoveRunning() && alcoveShowsSomething(state.settings.alcove)
    }

    private func capsule(_ geo: IslandScreenGeometry) -> Bool {
        geo.notch == nil || state.settings.islandShape == .kapsel || alcoveShowing(geo)
    }

    /// Texterkennung: while the user chooses a region the island is left out of screen pictures
    /// (sharingType .none, 04.10.: screencapture then leaves it out), so "Bereich wählen" can
    /// show in the capsule over the apps' content without landing in the picture. Only then: the
    /// island stays in screen recordings (Nils records VoiceBud for the course videos).
    private var captureExcluded = false
    func excludeFromCapture(_ on: Bool) {
        captureExcluded = on
        panel?.sharingType = on ? .none : .readOnly
    }

    private var confirmDelay: Double? {
        let s = state.settings.confirmSeconds
        if s >= 60 { return nil }          // "immer": stays until the next take
        return max(0.3, s)
    }

    private func beginTake(at phase: Phase) {
        cancelTimers()
        guard let screen = screenUnderMouse() else { return }
        let geo = IslandScreenGeometry(screen: screen)
        let settings = state.settings
        let alcove = alcoveShowing(geo)
        let kind: IslandModel.Kind = capsule(geo) ? .capsule : .notch
        // SPEC §0: live text is its own switch, for the island and the capsule alike
        let flavour: IslandModel.Flavour = settings.liveText ? .live : .compact
        let capsuleTop = alcove ? (geo.notch?.height ?? geo.menuBarHeight) + 8 : geo.menuBarHeight + 8
        let reuse = model.presented && model.kind == kind && model.flavour == flavour
            && targetDisplay == geo.displayID && panel?.isVisible == true

        suppressed = settings.hideInFullscreen && isFullscreen(geo)
        targetDisplay = geo.displayID

        let configure = {
            self.model.kind = kind
            self.model.flavour = flavour
            self.model.capsuleTop = capsuleTop
            self.model.mode = self.state.mode
            self.model.recordingStart = self.state.recordingStarted ?? Date()
            self.model.frozenElapsed = phase == .recording ? nil : (self.model.frozenElapsed ?? 0)
            self.model.done = self.state.done
            self.model.errorMessage = self.state.errorMessage
            self.model.noticeOK = self.state.noticeOK
            self.model.brightWords = 6
            self.model.hover = .none
            self.model.phase = phase
        }

        if reuse {
            // the surface is still on screen: it morphs into the new take, glyphs swap
            quietly { model.contentSwap = true }
            update(configure)
            fadePanel(to: 1, duration: 0.1)
            return
        }

        // Start collapsed inside the notch (or as the capsule's tiny pill) with the panel fully
        // transparent, start the grow on the next frame, then fade the panel in over 0.1 s, so
        // the first frame never shows (SPEC §0).
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) {
            model.presented = false
            model.contentSwap = false
            apply(geo)
            configure()
        }
        orderIn(geo)
        // a panel shown before is reported on screen at once (04.10., measured): one that is not
        // (it has come loose from this Space, seen live at 17:33) is replaced right away instead of
        // after the heal timer's 0.4 s
        if !headless && !suppressed, let panel, !reallyOnScreen(panel), panelShownBefore {
            rebuildPanel("\(phase.rawValue) ordered in but not on screen (at once)")
            orderIn(geo)
        }
        panelShownBefore = !headless && !suppressed

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.update { self.model.presented = true }
            self.fadePanel(to: 1, duration: 0.1)
            // from now on the surface stays: later content changes swap instead of entering
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.model.presented else { return }
                    self.quietly { self.model.contentSwap = true }
                }
            }
        }
        presentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated { self?.verifyOnScreen() }
        }
    }

    private func dismiss(quick: Bool) {
        hideWork?.cancel()
        hideWork = nil
        presentWork?.cancel()
        presentWork = nil
        stopHoverTracking()
        guard model.presented || panel?.isVisible == true else {
            resetModel()
            return
        }
        trace("island -> dismiss")
        // glyphs must leave with the §0 leave transition, not the swap: that trait has to be
        // on screen for one frame before they are removed
        quietly { model.contentSwap = false }
        let collapse = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.update { self.model.presented = false }
        }
        presentWork = collapse
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: collapse)
        orderOutWork?.cancel()
        let fadeAt = quick ? 0.12 : 0.22
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.panel?.alphaValue = 1
            self.resetModel()
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeAt) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.orderOutWork === work else { return }
                self.fadePanel(to: 0, duration: 0.22)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeAt + 0.26, execute: work)
    }

    private func resetModel() {
        quietly {
            model.presented = false
            model.contentSwap = false
            model.phase = .idle
            model.done = nil
            model.errorMessage = nil
            model.frozenElapsed = nil
            model.hover = .none
        }
        model.cardFrame = .zero
    }

    private func scheduleHide(after seconds: Double?) {
        hideWork?.cancel()
        hideWork = nil
        hideDeadline = nil
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            self.hideDeadline = nil
            self.dismiss(quick: false)
        }
        hideWork = work
        hideDeadline = Date().addingTimeInterval(seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelTimers() {
        hideWork?.cancel()
        hideWork = nil
        hideDeadline = nil
        orderOutWork?.cancel()
        orderOutWork = nil
        presentWork?.cancel()
        presentWork = nil
        stopHoverTracking()
    }

    // MARK: Hover on the confirmation (SPEC §0, decided 03.10.)

    /// the pointer keeps the card up: inside it, or within the 0.6 s grace after it left
    private var hoverHolds: Bool { pointerInside || collapseWork != nil }
    /// a dictation's card or notice is on screen (Texterkennung waits with its own card)
    var showsDictationCard: Bool {
        model.presented && (model.phase == .done || model.phase == .error) && model.mode != .ocr && orderOutWork == nil
    }

    private func startHoverTracking() {
        // a panel held back for a fullscreen app is not on screen: nothing to hover
        guard state.settings.confirmHoverExpand, hoverTimer == nil, model.phase == .done,
              headless || !suppressed else { return }
        pointerInside = false
        parkedPointer = headless ? nil : NSEvent.mouseLocation
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointer() }
        }
        timer.tolerance = 1.0 / 120
        // .common: keeps polling while a menu is open or something is being dragged
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        collapseWork?.cancel()
        collapseWork = nil
        pointerInside = false
        parkedPointer = nil
        suspendedHide = nil
        virtualPointerInside = false
        panel?.ignoresMouseEvents = true
    }

    private func pollPointer() {
        guard hoverTimer != nil, model.phase == .done, model.presented else { return }
        let inside: Bool
        if headless {
            inside = virtualPointerInside
        } else {
            guard let panel, panel.isVisible, !suppressed else { return }
            let mouse = NSEvent.mouseLocation
            if let parked = parkedPointer {
                if abs(mouse.x - parked.x) < 0.5 && abs(mouse.y - parked.y) < 0.5 { return }
                parkedPointer = nil
            }
            var rect = cardScreenRect(in: panel)
            if !pointerInside && model.kind == .notch, let top = panel.screen?.frame.maxY {
                // entering: the strip over the menu bar does not count, so a pointer on its way to
                // a status item next to the notch neither unfolds the card nor loses its click
                rect = rect.intersection(CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                                                height: max(0, top - model.notch.height - rect.minY)))
            }
            inside = rect.contains(mouse)
        }
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside { pointerEntered() } else { pointerLeft() }
    }

    /// the card's laid-out (animated) frame, reported by the view in canvas points (top-left
    /// origin), converted to screen points; 1 pt of slack so the very top screen row counts
    private func cardScreenRect(in panel: NSWindow) -> CGRect {
        let r = model.cardFrame
        guard r.width > 1, r.height > 1 else { return .null }
        let f = panel.frame
        return CGRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
            .insetBy(dx: -1, dy: -1)
    }

    /// Pointer on the card: it takes clicks (copy button, scrolling), the auto-hide stops with
    /// its remaining time kept, and the same card unfolds to the whole text.
    private func pointerEntered() {
        collapseWork?.cancel()
        collapseWork = nil
        panel?.ignoresMouseEvents = false
        if let work = hideWork {
            work.cancel()
            hideWork = nil
            suspendedHide = max(0, hideDeadline?.timeIntervalSinceNow ?? 0)
            hideDeadline = nil
        }
        if model.hover != .expanded {
            IslandHaptic.tick()          // the card answers the pointer, as Alcove's island does
            update { self.model.hover = .expanded }
        }
        trace("hover -> expand (remaining \(String(format: "%.2f", suspendedHide ?? -1)) s)")
    }

    /// Pointer gone: click-through again at once; after 0.6 s the card folds back (collapse
    /// springs) and hides after the remaining confirmation time, at least 0.8 s.
    private func pointerLeft() {
        panel?.ignoresMouseEvents = true
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWork = nil
            if self.model.hover == .expanded { self.update { self.model.hover = .collapsed } }
            let hideIn = self.confirmDelay.map { _ in max(self.suspendedHide ?? 0, 0.8) }
            self.suspendedHide = nil
            self.scheduleHide(after: hideIn)
            self.trace("hover -> collapse, hide in \(hideIn.map { String(format: "%.2f s", $0) } ?? "never")")
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        trace("hover -> leave")
    }

    private func trace(_ message: String) {
        if IPC.tracing { IPC.log("trace \(message)") }
    }

    private func freezeTimer() {
        if model.frozenElapsed == nil {
            model.frozenElapsed = Date().timeIntervalSince(state.recordingStarted ?? model.recordingStart)
        }
    }

    /// Model changes without a global animation: every surface animates its width and height
    /// with its own value-scoped spring (SPEC §0). Reduce Motion: a 0.2 s cross-fade.
    private func update(_ body: @escaping () -> Void) {
        if model.reduceMotion {
            withAnimation(IslandMotion.crossFade, body)
        } else {
            body()
        }
    }

    private func quietly(_ body: () -> Void) {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet, body)
    }

    private func fadePanel(to alpha: CGFloat, duration: Double) {
        guard let panel, panel.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: alpha > 0 ? .easeOut : .easeIn)
            panel.animator().alphaValue = alpha
        }
    }

    // MARK: Panel and screens

    private func ensurePanel() -> IslandPanel {
        if let panel { return panel }
        let p = IslandPanel(size: model.canvas)
        p.sharingType = captureExcluded ? .none : .readOnly
        let host = IslandHostingView(rootView: IslandView(state: state, model: model))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: model.canvas)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
        return p
    }

    private func apply(_ geo: IslandScreenGeometry) {
        model.notch = geo.notch ?? CGSize(width: 185, height: geo.menuBarHeight)
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Re-measure the notch and re-place the panel when displays or scaling change. If the
    /// take's display is gone (lid closed, monitor unplugged), the island is dismissed rather
    /// than drawn with a stale shape (a fake notch on a screen without one).
    private func screensChanged() {
        guard model.presented, let panel else { return }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == targetDisplay
        }
        // a running recording moves to the screen under the pointer instead of vanishing
        let running = state.phase == .recording || state.phase == .processing
        guard let screen else {
            if running { beginTake(at: state.phase) } else { dismiss(quick: true) }
            return
        }
        let geo = IslandScreenGeometry(screen: screen)
        if geo.notch == nil && model.kind == .notch {
            if running { beginTake(at: state.phase) } else { dismiss(quick: true) }
            return
        }
        quietly { apply(geo) }
        panel.setFrameOrigin(geo.panelOrigin(for: model.canvas))
    }

    /// Alcove "Automatisch" (SPEC §0): VoiceBud takes the notch while Alcove shows nothing and
    /// moves below it while Alcove shows something. Decided at recording start. Alcove's notch
    /// content cannot be read; its idle activity setting plus "is audio playing" stand in.
    private func alcoveShowsSomething(_ mode: AlcoveMode) -> Bool {
        switch mode {
        case .dodge: return true
        case .takeover: return false
        case .auto:
            switch UserDefaults(suiteName: Self.alcoveBundleID)?.string(forKey: "idleActivity") {
            case "none": return false
            case "nowPlaying", nil: return Self.otherAudioPlaying()
            default: return true          // calendar and the like: Alcove shows it all the time
            }
        }
    }

    /// Some OTHER program plays sound right now (macOS 14.4+ process objects, no permission).
    /// The device-wide flag also counts VoiceBud's own start and stop sounds, and macOS keeps it
    /// up for seconds after a sound ends: a second take right after the first then looked like
    /// music and went to the capsule.
    static func otherAudioPlaying() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else {
            return audioOutputRunning()
        }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else {
            return audioOutputRunning()
        }
        let own: Set<pid_t> = [getpid(), getppid()]
        for object in objects {
            var pid: pid_t = 0
            var s = UInt32(MemoryLayout<pid_t>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &a, 0, nil, &s, &pid) == noErr, !own.contains(pid) else { continue }
            var running: UInt32 = 0
            s = UInt32(MemoryLayout<UInt32>.size)
            a.mSelector = kAudioProcessPropertyIsRunningOutput
            if AudioObjectGetPropertyData(object, &a, 0, nil, &s, &running) == noErr, running != 0 { return true }
        }
        return false
    }

    /// The default output device is playing for some process (no permission needed).
    static func audioOutputRunning() -> Bool {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
        else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private func isAlcoveRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.alcoveBundleID }
    }

    /// Frontmost app has an on-screen window covering the target screen. CGWindowList bounds
    /// need no screen-recording permission (CG coordinates: origin top-left of the primary).
    /// Two shapes count: the whole screen frame, and on notched screens the frame below the
    /// camera housing, which is where macOS puts native fullscreen windows there (top edge at
    /// safeAreaInsets.top, bottom edge at the screen bottom). A maximised window sits under the
    /// menu bar instead (top at the menu-bar height), so it is only accepted when the menu-bar
    /// band and the housing band differ (32 vs 33 pt on a 14" MacBook Pro); otherwise this
    /// second check stays off rather than hide the island for an ordinary window.
    private func isFullscreen(_ geo: IslandScreenGeometry) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? geo.frame.height
        let target = CGRect(x: geo.frame.minX, y: primaryHeight - geo.frame.maxY,
                            width: geo.frame.width, height: geo.frame.height)
        let housingCheck = geo.safeTop > 0 && abs(geo.menuBarHeight - geo.safeTop) >= 0.5
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            guard abs(bounds.minX - target.minX) < 2, abs(bounds.width - target.width) < 2,
                  abs(bounds.maxY - target.maxY) < 1 else { continue }
            let top = bounds.minY - target.minY
            if abs(top) < 1 { return true }
            if housingCheck && abs(top - geo.safeTop) < 0.5 { return true }
        }
        return false
    }

    // MARK: Sounds

    private func playSound(_ name: String) {
        guard state.settings.sounds, !headless,
              let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.22
        sound.play()
    }
}
