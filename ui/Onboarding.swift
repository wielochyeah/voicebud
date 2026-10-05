// Onboarding (first launch): calm steps in one fixed 720×560 window, one idea per step. Eleven steps
// with Alcove installed, ten without (the Alcove step only exists when Alcove is installed).
// Visual language = the hub (HubTheme, HubCard, squircles, tile pickers with the ring) and the
// real island (IslandView, islandSurface springs) for every animated preview. Plain SwiftUI only,
// so OnboardingRender.swift can draw every step headless with ImageRenderer.
//
// State comes from `OnboardingModel`. Today it is filled with mock values; later the Python core
// pushes permissions, model downloads, microphone levels and the test result into the same fields
// (see the IPC notes on each field) and `OnboardingActions` sends the user's requests back.
//
// SPEC §0 (RAM/speed): the window is built on `show()` and torn down completely on close (window,
// hosting controller, model). Nothing here owns a Timer: animations are TimelineViews and `.task`
// loops that live only while their step is on screen.
import AppKit
import SwiftUI

// MARK: - Model

@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, howItWorks, microphone, accessibility, inputMonitoring, models, testDictation,
             appearance, alcove, context, screenText, finish

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: return "Willkommen"
            case .howItWorks: return "So funktioniert’s"
            case .microphone: return "Mikrofon"
            case .accessibility: return "Bedienungshilfen"
            case .inputMonitoring: return "Eingabeüberwachung"
            case .models: return "Modelle"
            case .testDictation: return "Probediktat"
            case .appearance: return "Darstellung"
            case .alcove: return "Alcove"
            case .context: return "Mitlesen"
            case .screenText: return "Texterkennung"
            case .finish: return "Alles bereit"
            }
        }

        var permission: Permission? {
            switch self {
            case .microphone: return .microphone
            case .accessibility: return .accessibility
            case .inputMonitoring: return .inputMonitoring
            default: return nil
            }
        }
    }

    /// The three TCC permissions. All of them belong to the Python core (see `tccName`).
    enum Permission: String, CaseIterable {
        case microphone, accessibility, inputMonitoring

        /// "Systemeinstellungen öffnen": the matching pane under Datenschutz & Sicherheit. The UI
        /// helper may open it itself (`NSWorkspace.shared.open(url)`, needs no permission).
        var settingsURL: URL {
            let anchor: String
            switch self {
            case .microphone: anchor = "Privacy_Microphone"
            case .accessibility: anchor = "Privacy_Accessibility"
            case .inputMonitoring: anchor = "Privacy_ListenEvent"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    /// IPC: core → UI `{"type":"onboarding","permissions":{"microphone":"granted",…}}`
    enum Grant: String {
        /// not asked yet
        case missing
        /// the user pressed "Freigabe erteilen": macOS shows its dialog, then System Settings
        case requested
        /// microphone only (AVCaptureDevice.authorizationStatus == .denied): macOS will not ask
        /// again, the user has to switch it on in System Settings
        case denied
        case granted
    }

    struct ModelItem: Identifiable, Equatable {
        enum Phase: Equatable {
            case ready
            /// megabytes, from the core's download progress messages
            case downloading(receivedMB: Double, totalMB: Double)
            /// no connection; the core resumes by itself once it is back
            case paused(receivedMB: Double, totalMB: Double)
        }

        let id: String
        var role: String
        var name: String
        var sizeGB: Double
        var phase: Phase
    }

    enum TestPhase: Equatable {
        case ready
        case listening
        case working
        case result(text: String, seconds: Double)
    }

    enum ContextLevel: String, CaseIterable {
        case app, cursor, window
    }

    /// SPEC §0 (03.10.): three tiles. Kept local until Model.swift's AlcoveMode carries "auto".
    enum AlcoveChoice: String, CaseIterable {
        case dodge, auto, takeover
    }

    static var sampleTake: String { L("Ich teste gerade VoiceBud und bin gespannt, wie gut das mit meiner Stimme klappt.") }

    var step: Step = .welcome
    /// direction of the last step change (drives the slide direction)
    private(set) var forward = true

    var grants: [Permission: Grant] = [.microphone: .missing, .accessibility: .missing, .inputMonitoring: .missing]
    /// input monitoring takes effect only after the core restarts
    var restartNeeded = false
    /// IPC: the name macOS shows in its dialogs and in the privacy lists for the core. "Python" while
    /// the core runs on the venv interpreter (ANLEITUNG: "oft als Python"); "VoiceBud" once the app
    /// ships its own signed runtime. Every hint on the permission steps follows it.
    var tccName = "Python"

    /// IPC: core reports download progress for both models (Hugging Face, mlx-community)
    var models: [ModelItem] = [
        ModelItem(id: "whisper", role: "Spracherkennung", name: "Whisper turbo, 8-Bit", sizeGB: 0.9, phase: .ready),
        ModelItem(id: "qwen", role: "Textaufbereitung", name: "Qwen 3.5, 4B", sizeGB: 3.0,
                  phase: .downloading(receivedMB: 1360, totalMB: 3030)),
    ]

    /// IPC: core streams `level` messages (7 bands) only while the test dictation is visible;
    /// write them through `receiveLevels` so the silent-mic check sees them
    private(set) var micLevels: [Float] = Array(repeating: 0, count: 7)
    @ObservationIgnored private(set) var peakLevel: Float = 0
    var micDevice = L("MacBook Pro-Mikrofon")
    var test: TestPhase = .ready
    /// no signal 3 s into the test dictation: the footnote turns into the "Balken flach" help
    var flatSignal = false

    var islandShape: IslandStyle = .insel
    var alcoveInstalled = OnboardingProbe.alcoveInstalled()
    var alcove: AlcoveChoice = .auto
    var context: ContextLevel = .cursor
    var launchAtLogin = true
    var hotkeys: [String: String] = ["dictate": "ctrl+shift", "prompt": "ctrl+alt"]

    /// true while nothing feeds the model (the window was opened without the core): levels are
    /// synthetic and pressing the big keys plays a scripted test dictation
    var mock = true

    /// renders only: steps draw one deterministic frame; the hero freezes at this phase
    @ObservationIgnored var rendering = false
    @ObservationIgnored var stillHero: Phase = .done

    @ObservationIgnored var actions = OnboardingActions()
    @ObservationIgnored private var demo: Task<Void, Never>?

    init() {}

    // MARK: Navigation

    /// the steps this Mac gets: the Alcove step only when Alcove is installed
    var steps: [Step] { Step.allCases.filter { $0 != .alcove || alcoveInstalled } }
    var position: Int { steps.firstIndex(of: step) ?? 0 }
    var isFirst: Bool { position == 0 }
    var isLast: Bool { step == steps.last }

    var testDone: Bool {
        if case .result = test { return true }
        return false
    }

    /// one primary button per screen: "Weiter" stays quiet until the step's job is done
    var advanceIsPrimary: Bool {
        if let p = step.permission { return grants[p] == .granted && !(p == .inputMonitoring && restartNeeded) }
        if step == .testDictation { return testDone }
        return true
    }

    var advanceTitle: String {
        if isLast { return L("Los geht’s") }
        if step == .testDictation && !testDone { return L("Überspringen") }
        return L("Weiter")
    }

    func next() {
        if isLast {
            actions.finish()
            if screenTextAsked && !screenTextGranted { actions.restartCore() }   // the permission needs it
            return
        }
        go(to: steps[position + 1])
    }

    func back() {
        guard position > 0 else { return }
        go(to: steps[position - 1])
    }

    func go(to target: Step) {
        guard target != step else { return }
        let old = step
        let isForward = target.rawValue > old.rawValue
        // the leaving step must have rendered with the new direction before it is removed,
        // otherwise it slides out the old way
        if isForward != forward {
            forward = isForward
            DispatchQueue.main.async { [weak self] in self?.commit(target, from: old) }
        } else {
            commit(target, from: old)
        }
    }

    private func commit(_ target: Step, from old: Step) {
        step = target
        stepChanged(from: old, to: target)
    }

    /// Tells the core what to watch while a step is visible (and to stop when it leaves).
    private func stepChanged(from old: Step, to new: Step) {
        if old == .testDictation {
            actions.micLevels(false)
            stopDemo()
        }
        if new == .testDictation { actions.micLevels(true) }
        let watching = new.permission != nil
        if watching != (old.permission != nil) { actions.watchPermissions(watching) }
    }

    /// window closing: stop everything the steps asked the core for
    func leave() {
        if step == .testDictation { actions.micLevels(false) }
        if step.permission != nil { actions.watchPermissions(false) }
        stopDemo()
    }

    // MARK: Requests

    func request(_ p: Permission) {
        if grants[p] != .granted { grants[p] = .requested }
        actions.requestPermission(p)
    }

    func openSettings(_ p: Permission) { actions.openSettings(p) }
    func revealCore() { actions.revealCore() }
    func restartCore() { actions.restartCore() }

    /// Texterkennung (⇧⌘2) needs Screen Recording: macOS asks once, and the permission only works
    /// after a restart, so the setup restarts VoiceBud at the end when it was asked for here
    var screenTextAsked = false
    /// renders: the state to draw (the rendering process may hold the permission itself)
    var screenTextPreview: Bool?
    var screenTextGranted: Bool { screenTextPreview ?? CGPreflightScreenCaptureAccess() }

    func requestScreenText() {
        if screenTextGranted { return }
        if !screenTextAsked {
            screenTextAsked = true
            _ = CGRequestScreenCaptureAccess()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    func openSoundSettings() { actions.openSoundSettings() }
    func retryDownload(_ id: String) { actions.retryDownload(id) }

    func receiveLevels(_ bands: [Float]) {
        micLevels = bands
        peakLevel = max(peakLevel, bands.max() ?? 0)
    }

    func resetPeak() { peakLevel = 0 }

    func retryTest() {
        stopDemo()
        test = .ready
        flatSignal = false
        actions.retryTest()
    }

    /// mock window only: a scripted take, so the step can be tried without the core
    func simulateTest() {
        guard mock, !rendering, demo == nil else { return }
        flatSignal = false
        test = .listening
        demo = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled, let self else { return }
            self.test = .working
            try? await Task.sleep(for: .seconds(0.7))
            guard !Task.isCancelled else { return }
            self.test = .result(text: Self.sampleTake, seconds: 0.4)
            self.demo = nil
        }
    }

    private func stopDemo() {
        demo?.cancel()
        demo = nil
    }

    func choicesChanged() { actions.choicesChanged(self) }
}

/// Everything the onboarding asks of the outside world. The core wiring fills these in; the
/// defaults do nothing, so renders and the mock window are side-effect free.
struct OnboardingActions {
    /// UI → core `{"type":"permission_request","which":"microphone"}`: mic → AVCaptureDevice
    /// request; accessibility → AXIsProcessTrustedWithOptions(prompt: true); input monitoring →
    /// IOHIDRequestAccess. The last two show Apple's dialog with "Systemeinstellungen öffnen",
    /// which the hints on steps 4 and 5 name.
    var requestPermission: @MainActor (OnboardingModel.Permission) -> Void = { _ in }
    /// "Systemeinstellungen öffnen" (requested / denied): open `permission.settingsURL`
    var openSettings: @MainActor (OnboardingModel.Permission) -> Void = { _ in }
    /// core polls AXIsProcessTrusted / IOHIDCheckAccess while a permission step is visible
    var watchPermissions: @MainActor (Bool) -> Void = { _ in }
    /// reveal the core's Python.app in the Finder (drag it into the list if it is missing)
    var revealCore: @MainActor () -> Void = {}
    /// UI → core `{"type":"restart"}`; the onboarding must come back at step 5 afterwards
    var restartCore: @MainActor () -> Void = {}
    var retryDownload: @MainActor (String) -> Void = { _ in }
    /// System Settings → Ton (x-apple.systempreferences:com.apple.Sound-Settings.extension)
    var openSoundSettings: @MainActor () -> Void = {}
    /// start / stop the 7-band level stream for the test dictation
    var micLevels: @MainActor (Bool) -> Void = { _ in }
    var retryTest: @MainActor () -> Void = {}
    /// shape, Alcove, context level, launch at login changed → write settings.json
    var choicesChanged: @MainActor (OnboardingModel) -> Void = { _ in }
    var finish: @MainActor () -> Void = {}
}

@MainActor
enum OnboardingProbe {
    static func alcoveInstalled() -> Bool { AlcoveProbe.installed() }
}

// MARK: - Window controller

@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private(set) var model: OnboardingModel?
    private let makeModel: @MainActor () -> OnboardingModel
    /// called after the window closed (the hub uses it to decide the activation policy)
    var onClose: @MainActor () -> Void = {}

    init(makeModel: @escaping @MainActor () -> OnboardingModel = { OnboardingModel() }) {
        self.makeModel = makeModel
        super.init()
    }

    var isOpen: Bool { window != nil }
    /// the live window (tests capture it; nil while closed)
    var currentWindow: NSWindow? { window }

    private var headless: Bool { ProcessInfo.processInfo.environment["VOICEBUD_UI_HEADLESS"] == "1" }

    func show() {
        if let window {
            if headless { return }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let model = makeModel()
        let finish = model.actions.finish
        model.actions.finish = { [weak self] in
            finish()
            self?.close()
        }
        self.model = model
        let window = makeWindow(model: model)
        self.window = window
        // tests drive the model and capture the window; nothing goes on screen, no focus taken
        if headless { return }
        NSApp.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// `close()`, not `performClose`: the latter silently does nothing for a window that is not on
    /// screen, and then windowWillClose never runs and the whole tree stays in memory
    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        model?.leave()
        let closing = window
        window = nil
        model = nil
        // drop the SwiftUI tree right away: no hero loop, no waveform, nothing held while closed
        DispatchQueue.main.async {
            closing?.contentViewController = nil
            closing?.delegate = nil
        }
        onClose()
    }

    private func makeWindow(model: OnboardingModel) -> NSWindow {
        let host = NSHostingController(rootView: OnboardingRootView(model: model))
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        let size = OnboardingLayout.size
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(size)
        w.title = L("VoiceBud einrichten")
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.delegate = self
        return w
    }
}

// MARK: - Tokens

enum OnboardingLayout {
    static let size = CGSize(width: 720, height: 560)
    static let footerHeight: CGFloat = 68
    /// transparent titlebar with the close button
    static let titlebar: CGFloat = 32
    /// the only two content widths
    static let column: CGFloat = 560
    static let narrow: CGFloat = 400
    static var windowRadius: CGFloat {
        if #available(macOS 26, *) { return 16 }
        return 10
    }
}

/// The only gaps between blocks: 8 / 12 / 16 / 24.
enum OnboardingGap {
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
}

/// Title 22 bold (intro 28), body 13, secondary 12. Nothing else for UI copy.
enum OnboardingType {
    static let introTitle = Font.system(size: 28, weight: .bold)
    static let title = Font.system(size: 22, weight: .bold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let secondary = Font.system(size: 12)
    static let secondaryMedium = Font.system(size: 12, weight: .medium)
}

extension HubTheme {
    /// every onboarding sentence: light fg2 raised to #3C3C43 at 80 % (about 5.5:1 on the window,
    /// 5.9:1 on cards); dark keeps the hub's fg2 (5.9:1)
    var prose: Color { dark ? fg2 : Color(hex: 0x3C3C43, opacity: 0.80) }
    /// accent-coloured text (links, the "Empfohlen" pill): #6A4BD6 in light mode (4.75:1)
    var accentText: Color { dark ? Color(hex: 0xB89EFA) : Color(hex: 0x6A4BD6) }
    var warn: Color { Color(hex: 0xFF9F0A) }
}

private let onboardingSpring = Animation.spring(response: 0.42, dampingFraction: 0.86)

// MARK: - Root

struct OnboardingRootView: View {
    let model: OnboardingModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let t = HubTheme(scheme)
        VStack(spacing: 0) {
            ZStack {
                OnboardingStepView(model: model, step: model.step)
                    .id(model.step)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            OnboardingFooter(model: model)
        }
        .frame(width: OnboardingLayout.size.width, height: OnboardingLayout.size.height)
        .background(t.windowBg)
        // the window's titlebar is transparent: the layout owns the full 560 pt, as designed,
        // instead of losing 32 pt at the top and pushing the buttons onto the bottom edge
        .ignoresSafeArea()
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : onboardingSpring, value: model.step)
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        let d: CGFloat = model.forward ? 1 : -1
        return .asymmetric(
            insertion: .offset(x: 26 * d).combined(with: .opacity),
            removal: .offset(x: -26 * d).combined(with: .opacity))
    }
}

/// The same window as drawn by AppKit (rounded, hairline, close button), for headless renders.
struct OnboardingStaticWindow: View {
    let model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        let shape = RoundedRectangle(cornerRadius: OnboardingLayout.windowRadius, style: .continuous)
        OnboardingRootView(model: model)
            .overlay(alignment: .topLeading) {
                Circle().fill(Color(hex: 0xFF5F57))
                    .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    .frame(width: 14, height: 14)
                    .padding(.leading, 9)
                    .padding(.top, 9)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(t.windowStroke, lineWidth: 0.5))
            .environment(\.hubStatic, true)
    }
}

struct OnboardingStepView: View {
    let model: OnboardingModel
    let step: OnboardingModel.Step

    var body: some View {
        switch step {
        case .welcome: OnboardingWelcome(model: model)
        case .howItWorks: OnboardingHowItWorks(model: model)
        case .microphone, .accessibility, .inputMonitoring: OnboardingPermissionStep(model: model, step: step)
        case .models: OnboardingModels(model: model)
        case .testDictation: OnboardingTestDictation(model: model)
        case .appearance: OnboardingAppearance(model: model)
        case .alcove: OnboardingAlcove(model: model)
        case .context: OnboardingContext(model: model)
        case .screenText: OnboardingScreenText(model: model)
        case .finish: OnboardingFinish(model: model)
        }
    }
}

// MARK: - Page skeleton

/// Places its one child centred between the titlebar and the footer, lifted by 12 pt, but never
/// closer than 24 pt to the titlebar. Every step uses it, so top and bottom gaps balance.
struct OnboardingCentered: Layout {
    var minTop: CGFloat = OnboardingGap.l
    var lift: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? OnboardingLayout.size.width,
               height: proposal.height ?? (OnboardingLayout.size.height - OnboardingLayout.footerHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let top = max(minTop, ((bounds.height - size.height) / 2 - lift).rounded())
            view.place(at: CGPoint(x: bounds.midX, y: bounds.minY + top), anchor: .top,
                       proposal: ProposedViewSize(width: bounds.width, height: size.height))
        }
    }
}

/// Step body: one centred column in the area below the titlebar.
struct OnboardingPage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        OnboardingCentered {
            VStack(spacing: 0) { content }
        }
        .padding(.top, OnboardingLayout.titlebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Footer: Zurück, progress, Weiter

struct OnboardingFooter: View {
    let model: OnboardingModel

    var body: some View {
        ZStack {
            OnboardingProgress(count: model.steps.count, index: model.position)
            HStack(spacing: 0) {
                if !model.isFirst {
                    Button(L("Zurück")) { model.back() }
                        .buttonStyle(OnboardingButtonStyle(kind: .secondary))
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                // Return goes to the one primary button: here, or the step's own primary action
                Button(model.advanceTitle) { model.next() }
                    .buttonStyle(OnboardingButtonStyle(kind: model.advanceIsPrimary ? .primary : .secondary,
                                                       minWidth: 104))
                    .keyboardShortcut(model.advanceIsPrimary ? .defaultAction : nil)
            }
        }
        .padding(.horizontal, OnboardingGap.l)
        .frame(height: OnboardingLayout.footerHeight)
    }
}

/// Thin segmented bar: one segment per step, filled up to the current one.
struct OnboardingProgress: View {
    let count: Int
    let index: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= index ? t.accent : t.trackOff)
                    .frame(width: 18, height: 3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L("Schritt %d von %d", index + 1, count))
    }
}

struct OnboardingButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind
    var minWidth: CGFloat = 92

    func makeBody(configuration: Configuration) -> some View {
        OnboardingButtonBody(label: configuration.label, kind: kind, pressed: configuration.isPressed, minWidth: minWidth)
    }
}

private struct OnboardingButtonBody<Label: View>: View {
    let label: Label
    let kind: OnboardingButtonStyle.Kind
    let pressed: Bool
    let minWidth: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let t = HubTheme(scheme)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let primary = kind == .primary
        let fill: Color = primary ? t.accent : (t.dark ? Color.white.opacity(0.12) : Color.white)
        let edge: Color = primary ? Color.black.opacity(0.08) : (t.dark ? Color.white.opacity(0.08) : Color.black.opacity(0.13))
        let text: Color = primary ? Color.white : t.fg
        let shadow: Double = primary || t.dark ? 0 : 0.05
        label
            .font(.system(size: 13, weight: primary ? .semibold : .medium))
            .foregroundStyle(text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, OnboardingGap.m)
            .frame(minWidth: minWidth, minHeight: 30)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(edge, lineWidth: 0.5))
            .shadow(color: .black.opacity(shadow), radius: 0.5, y: 0.5)
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
            .animation(onboardingSpring, value: primary)
    }
}

// MARK: - Shared pieces

/// Title + one calm sentence, centred.
struct OnboardingHeader: View {
    let title: String
    var subtitle: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        VStack(spacing: OnboardingGap.xs) {
            Text(title)
                .font(OnboardingType.title)
                .foregroundStyle(t.fg)
            if let subtitle {
                Text(subtitle)
                    .font(OnboardingType.body)
                    .foregroundStyle(t.prose)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: OnboardingLayout.column)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 12 pt note under a card. `lines` reserves room, so a page never shifts when the text changes.
struct OnboardingFootnote: View {
    let text: String
    var lines = 1
    var model: OnboardingModel?
    @Environment(\.colorScheme) private var scheme

    init(_ text: String, lines: Int = 1, model: OnboardingModel? = nil) {
        self.text = text
        self.lines = lines
        self.model = model
    }

    var body: some View {
        OnboardingRichText(text: text, model: model)
            .font(OnboardingType.secondary)
            .foregroundStyle(HubTheme(scheme).prose)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: CGFloat(lines) * 16, alignment: .topLeading)
            .padding(.horizontal, 6)
            .padding(.top, OnboardingGap.xs)
    }
}

/// Copy with optional inline links (`[Im Finder zeigen](voicebud://reveal)`), tinted in the
/// accent text colour; the links call the model instead of opening anything.
struct OnboardingRichText: View {
    let text: String
    var model: OnboardingModel?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if text.contains("](voicebud://") {
            Text(LocalizedStringKey(text))
                .tint(HubTheme(scheme).accentText)
                .environment(\.openURL, OpenURLAction { url in
                    MainActor.assumeIsolated {
                        switch url.host {
                        case "reveal": model?.revealCore()
                        case "sound": model?.openSoundSettings()
                        default: break
                        }
                    }
                    return .handled
                })
        } else {
            Text(verbatim: text)
        }
    }
}

/// HubRow with the onboarding's type scale (title 13, subtitle 12 in `prose`).
struct OnboardingRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let trailing: Trailing
    @Environment(\.colorScheme) private var scheme

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        let t = HubTheme(scheme)
        HStack(spacing: OnboardingGap.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(OnboardingType.body).foregroundStyle(t.fg)
                if let subtitle {
                    Text(subtitle)
                        .font(OnboardingType.secondary)
                        .foregroundStyle(t.prose)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: OnboardingGap.s)
            trailing
        }
        .padding(.horizontal, OnboardingGap.s)
        .padding(.vertical, subtitle == nil ? 0 : 10)
        .frame(minHeight: 44)
    }
}

/// Status word with its mark: green check, orange dot, grey dot or the spinner.
struct OnboardingStatus: View {
    enum Mark { case ok, warn, idle, busy, rec }
    let mark: Mark
    let text: String
    var large = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        HStack(spacing: large ? 7 : 6) {
            switch mark {
            case .ok:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: large ? 15 : 13, weight: .semibold))
                    .foregroundStyle(t.ok)
            case .warn:
                Circle().fill(t.warn).frame(width: 8, height: 8)
            case .idle:
                Circle().fill(t.fg3).frame(width: 7, height: 7)
            case .busy:
                OnboardingSpinner(size: 12)
            case .rec:
                HubRecDot(size: 6)
            }
            let quiet = mark == .idle || mark == .busy
            Text(text)
                .font(large ? (quiet ? OnboardingType.body : OnboardingType.bodyMedium)
                            : (quiet ? OnboardingType.secondary : OnboardingType.secondaryMedium))
                .foregroundStyle(quiet ? t.prose : t.fg)
        }
    }
}

struct OnboardingSpinner: View {
    var size: CGFloat = 12
    @Environment(\.colorScheme) private var scheme
    @Environment(\.hubStatic) private var isStatic

    var body: some View {
        if isStatic {
            ring(70)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
                ring(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360)
            }
        }
    }

    private func ring(_ degrees: Double) -> some View {
        let t = HubTheme(scheme)
        return ZStack {
            Circle().stroke(t.trackOff, lineWidth: 1.8)
            Circle().trim(from: 0, to: 0.28)
                .stroke(t.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(degrees - 90))
        }
        .frame(width: size, height: size)
    }
}

/// Modifier glyphs as SF Symbols: "control" and "shift" are optically centred at the same point
/// size (the ⌃ character sits 4 pt higher than ⇧ in the system font).
enum OnboardingKeys {
    static func symbol(_ glyph: String) -> String? {
        switch glyph {
        case "⌃": return "control"
        case "⇧": return "shift"
        case "⌥": return "option"
        case "⌘": return "command"
        default: return nil
        }
    }

    /// what is printed on the physical key of a German Mac keyboard (shift only has the arrow
    /// there; "shift" is the name people use for it)
    static func word(_ glyph: String) -> String {
        // English: the words on a US/UK Mac keyboard (control, option, command)
        switch glyph {
        case "⌃": return L("ctrl")
        case "⇧": return "shift"
        case "⌥": return L("alt")
        case "⌘": return L("cmd")
        default: return ""
        }
    }

    static func glyph(_ k: String, size: CGFloat, weight: Font.Weight = .medium) -> some View {
        Group {
            if let s = symbol(k) {
                Image(systemName: s).font(.system(size: size, weight: weight))
            } else {
                Text(k).font(.system(size: size * 0.95, weight: weight))
            }
        }
    }
}

/// Small key caps (22 pt) with symbol glyphs.
struct OnboardingKeyCaps: View {
    let keys: [String]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                OnboardingKeys.glyph(k, size: 11)
                    .foregroundStyle(t.fg)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, k.count > 1 ? 4 : 0)
                    .background(shape.fill(t.capsuleBg))
                    .overlay(shape.strokeBorder(t.capsuleStroke, lineWidth: 0.5))
            }
        }
    }
}

/// "Drück [⌃][⇧] in …": text with key caps on the text line.
struct OnboardingKeyLine: View {
    let before: String
    let keys: [String]
    let after: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        let tight = after.first.map { ",.;:".contains($0) } ?? false
        HStack(alignment: .center, spacing: 0) {
            Text(before)
            OnboardingKeyCaps(keys: keys)
                .padding(.leading, 6)
                .padding(.trailing, tight ? 2 : 6)
            Text(after)
        }
        .font(OnboardingType.body)
        .foregroundStyle(t.prose)
    }
}

enum OnboardingAppIcon {
    /// The app icon (assets/AppIcon.icns, or the copy inside VoiceBud.app next to the binary).
    /// Loaded by the step that shows it and released with it, never cached (SPEC §0).
    static func load() -> NSImage? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let dir = exe.deletingLastPathComponent()
        let candidates = [
            dir.appendingPathComponent("AppIcon.icns"),
            dir.appendingPathComponent("../Resources/AppIcon.icns").standardizedFileURL,
            dir.appendingPathComponent("../../assets/AppIcon.icns").standardizedFileURL,
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }
}

enum OnboardingLoop {
    /// sleeps inside a `.task` loop; false once the task is cancelled (step or window gone)
    static func pause(_ seconds: Double) async -> Bool {
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return false }
        return !Task.isCancelled
    }
}

/// Tiles with a preview, a title, an optional one-line detail and badge; one ring springs
/// between them (matchedGeometryEffect), like HubTilePicker, with the onboarding's type scale.
struct OnboardingTileOption<Value: Hashable> {
    let value: Value
    let title: String
    var detail: String?
    var badge: String?
}

struct OnboardingTilePicker<Value: Hashable, Preview: View>: View {
    let options: [OnboardingTileOption<Value>]
    let selection: Value
    var tileHeight: CGFloat = 56
    let select: (Value) -> Void
    let preview: (Value) -> Preview
    @Namespace private var ns
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(options: [OnboardingTileOption<Value>], selection: Value, tileHeight: CGFloat = 56,
         select: @escaping (Value) -> Void, @ViewBuilder preview: @escaping (Value) -> Preview) {
        self.options = options
        self.selection = selection
        self.tileHeight = tileHeight
        self.select = select
        self.preview = preview
    }

    var body: some View {
        let t = HubTheme(scheme)
        HStack(alignment: .top, spacing: OnboardingGap.s) {
            ForEach(options, id: \.value) { option in
                tile(option, t: t)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(t.ring, lineWidth: 2.5)
                .padding(-4)
                .matchedGeometryEffect(id: selection, in: ns, isSource: false)
                .allowsHitTesting(false)
        }
        .padding(OnboardingGap.s)
    }

    private func tile(_ option: OnboardingTileOption<Value>, t: HubTheme) -> some View {
        let selected = option.value == selection
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return Button {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.74)) {
                select(option.value)
            }
        } label: {
            VStack(spacing: 0) {
                preview(option.value)
                    .frame(maxWidth: .infinity)
                    .frame(height: tileHeight)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(t.tileEdge, lineWidth: 1))
                    .matchedGeometryEffect(id: option.value, in: ns, isSource: true)
                HStack(spacing: 6) {
                    Text(option.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? t.fg : t.prose)
                    if let badge = option.badge {
                        Text(badge)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(t.accentText)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Capsule().fill(t.accent.opacity(t.dark ? 0.22 : 0.12)))
                    }
                }
                .padding(.top, OnboardingGap.xs)
                if let detail = option.detail {
                    Text(detail)
                        .font(OnboardingType.secondary)
                        .foregroundStyle(t.prose)
                        .multilineTextAlignment(.center)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HubPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 1 Willkommen

struct OnboardingWelcome: View {
    let model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        VStack(spacing: 0) {
            OnboardingHero(still: model.rendering ? model.stillHero : nil)
                .padding(.top, 40)
            Spacer(minLength: 0)
            VStack(spacing: OnboardingGap.s) {
                Text("VoiceBud")
                    .font(OnboardingType.introTitle)
                    .foregroundStyle(t.fg)
                // intro lede: the one place with a larger sentence, like the intro title
                Text(L("Du sprichst, VoiceBud schreibt.\nAlles bleibt auf deinem Mac."))
                    .font(.system(size: 15))
                    .foregroundStyle(t.prose)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            Spacer(minLength: 0)
            Text(L("Auf Macs ohne Notch erscheint VoiceBud als Kapsel unter der Menüleiste."))
                .font(OnboardingType.secondary)
                .foregroundStyle(t.prose)
                .padding(.bottom, OnboardingGap.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The real island (IslandView) on a 1:1 crop of the screen top: it grows out of the notch with
/// the waveform, turns into the spinner, then the done card, and folds back. Runs only while
/// step 1 is visible (`.task` is cancelled when the step or the window goes away).
struct OnboardingHero: View {
    static let size = CGSize(width: 672, height: 200)
    static let notch = CGSize(width: 185, height: 32)
    static var done: DoneInfo {
        let text = L("Morgen um zehn mit Lena die Folien durchgehen.")
        return DoneInfo(app: L("Notizen"), words: text.split(whereSeparator: \.isWhitespace).count, seconds: 0.4,
                        preview: text, toClipboard: false)
    }

    /// non-nil: a render, frozen at this phase; nil: the live loop
    let still: Phase?
    @State private var driver: OnboardingHeroDriver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    init(still: Phase?) {
        self.still = still
        _driver = State(initialValue: OnboardingHeroDriver(still: still))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack(alignment: .top) {
            OnboardingHeroBackdrop(notch: Self.notch)
            OnboardingMenuBar(notch: Self.notch.width)
            IslandView(state: driver.state, model: driver.island)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(HubTheme(scheme).tileEdge, lineWidth: 0.5))
        .task {
            guard still == nil else { return }
            await driver.loop(reduceMotion: reduceMotion)
        }
    }
}

/// Wallpaper, menu bar tint and the hardware notch. The notch is drawn exactly as tall and round
/// as the closed island (notch height - 4, radius 9), so it never shows under the island while
/// the island's height spring is still catching up with its width.
struct OnboardingHeroBackdrop: View {
    let notch: CGSize

    var body: some View {
        ZStack(alignment: .top) {
            RadialGradient(stops: [.init(color: Color(hex: 0x5A4BB0), location: 0),
                                   .init(color: Color(hex: 0x2C2470), location: 0.42),
                                   .init(color: Color(hex: 0x130F33), location: 1)],
                           center: UnitPoint(x: 0.18, y: 0), startRadius: 0, endRadius: 600)
            Rectangle().fill(Color(hex: 0x120E2E, opacity: 0.16)).frame(height: notch.height + 1)
            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                .fill(Color.black)
                .frame(width: notch.width, height: notch.height - 4)
        }
    }
}

@MainActor
@Observable
final class OnboardingHeroDriver {
    let state: AppState
    let island: IslandModel

    init(still: Phase?) {
        state = AppState()
        state.settings.waveStyle = .sym
        state.settings.waveLive = false
        state.settings.liveText = false
        island = IslandModel()
        island.notch = OnboardingHero.notch
        island.canvas = OnboardingHero.size
        island.kind = .notch
        island.flavour = .compact
        if let still {
            freeze(still)
        } else {
            // live: start folded inside the notch; the loop grows it on the next beat
            island.presented = false
            island.phase = .idle
        }
    }

    /// deterministic frame for renders
    func freeze(_ phase: Phase) {
        island.stillTime = 0.75
        island.presented = phase != .idle
        island.phase = phase
        island.done = OnboardingHero.done
        island.frozenElapsed = 3
        state.phase = phase
        state.bands = [0.45, 0.7, 0.9, 0.75, 0.55, 0.38, 0.22]
    }

    /// closed notch → recording (grows, waveform) → processing → done card → folds back, forever
    func loop(reduceMotion: Bool) async {
        island.stillTime = nil
        island.reduceMotion = reduceMotion
        quietly {
            island.presented = false
            island.contentSwap = false
            island.phase = .idle
        }
        while !Task.isCancelled {
            guard await pause(0.9) else { return }
            quietly {
                island.contentSwap = false
                island.recordingStart = Date()
                island.frozenElapsed = nil
                island.phase = .recording
            }
            update { self.island.presented = true }
            guard await pause(0.06) else { return }
            quietly { island.contentSwap = true }
            guard await pause(2.8) else { return }
            island.frozenElapsed = 2.8
            update { self.island.phase = .processing }
            guard await pause(0.9) else { return }
            island.done = OnboardingHero.done
            update { self.island.phase = .done }
            guard await pause(3.2) else { return }
            quietly { island.contentSwap = false }
            guard await pause(0.02) else { return }
            update { self.island.presented = false }
            guard await pause(0.7) else { return }
            quietly {
                island.phase = .idle
                island.done = nil
            }
        }
    }

    private func pause(_ seconds: Double) async -> Bool {
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return false }
        return !Task.isCancelled
    }

    private func update(_ body: @escaping () -> Void) {
        if island.reduceMotion { withAnimation(IslandMotion.crossFade, body) } else { body() }
    }

    private func quietly(_ body: () -> Void) {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet, body)
    }
}

/// Menu bar items around the notch, so the hero reads as the top of your Mac at a glance.
struct OnboardingMenuBar: View {
    let notch: CGFloat

    var body: some View {
        // only as many items as stay visible beside the widest card (the 400 pt done card)
        HStack(spacing: 0) {
            HStack(spacing: 17) {
                Image(systemName: "apple.logo").font(.system(size: 13.5))
                Text(L("Notizen")).font(.system(size: 13, weight: .bold))
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notch)
            HStack(spacing: 15) {
                Image(systemName: "mic.fill").font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "wifi").font(.system(size: 12.5, weight: .semibold))
                Text("9:41")
            }
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.92))
        .frame(height: OnboardingHero.notch.height)
    }
}

// MARK: - 2 So funktioniert’s

struct OnboardingHowItWorks: View {
    let model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        OnboardingPage {
            OnboardingHeader(title: L("So funktioniert’s"), subtitle: L("Drei Tastenkürzel, die in jeder App funktionieren."))
                .padding(.bottom, OnboardingGap.l)
            HubCard {
                OnboardingGestureRow(title: L("Diktieren"),
                                     text: L("Drücken, sprechen, noch einmal drücken.\nDer Text landet an deinem Cursor.")) {
                    OnboardingKeyCaps(keys: HubFormat.hotkey(model.hotkeys["dictate"] ?? "ctrl+shift"))
                } preview: {
                    OnboardingMiniIsland(mode: .dictate)
                }
                HubSeparator()
                OnboardingGestureRow(title: L("Prompt erstellen"),
                                     text: L("Sag grob, was du von einer KI willst.\nVoiceBud schreibt daraus einen klaren Prompt.")) {
                    OnboardingKeyCaps(keys: HubFormat.hotkey(model.hotkeys["prompt"] ?? "ctrl+alt"))
                } preview: {
                    OnboardingMiniIsland(mode: .prompt)
                }
                HubSeparator()
                OnboardingGestureRow(title: L("Text umschreiben"),
                                     text: L("Text markieren, halten und sagen, was passieren soll.\nEtwa „mach das kürzer“ oder „förmlicher“.")) {
                    OnboardingKeyCaps(keys: HubFormat.hotkey(model.hotkeys["command"] ?? "ctrl+cmd"))
                } preview: {
                    OnboardingMiniIsland(mode: .command)
                }
            }
            .frame(width: OnboardingLayout.column)
            OnboardingFootnote(L("Fährst du mit der Maus über die Meldung in der Notch, klappt der ganze Text auf."), lines: 1)
                .frame(width: OnboardingLayout.column)
        }
    }
}

struct OnboardingGestureRow<Keys: View, Preview: View>: View {
    let title: String
    let text: String
    let keys: Keys
    let preview: Preview
    @Environment(\.colorScheme) private var scheme

    init(title: String, text: String, @ViewBuilder keys: () -> Keys, @ViewBuilder preview: () -> Preview) {
        self.title = title
        self.text = text
        self.keys = keys()
        self.preview = preview()
    }

    var body: some View {
        let t = HubTheme(scheme)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: OnboardingGap.m) {
            preview
                .frame(width: 176, height: 86)
                .clipShape(shape)
                .overlay(shape.strokeBorder(t.tileEdge, lineWidth: 1))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Spacer(minLength: OnboardingGap.xs)
                    keys
                }
                Text(text)
                    .font(OnboardingType.secondary)
                    .foregroundStyle(t.prose)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(OnboardingGap.s)
    }
}

/// The island at about one third: a 58 × 12 notch, 7 pt text. Same surfaces and springs as the
/// real one (islandSurface: width 150/20 and 200/20, height and radii 250/21 and 250/25, each on
/// its own value-scoped animation; content enters with blur and scaleX, swaps with scale 0.8,
/// blur(h/6) and the 150/14 spring).
enum OnboardingMini {
    static let notch = CGSize(width: 58, height: 12)
    static let text: CGFloat = 7

    /// drawn exactly like the closed island, so nothing peeks out while it grows
    static func hardwareNotch() -> some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
            .fill(Color.black)
            .frame(width: notch.width, height: notch.height)
    }

    static let closed = IslandSurfaceGeometry(width: notch.width, height: notch.height, top: 0, bottom: 4)

    static func check(_ mode: Mode) -> some View {
        IslandCheckBadge(mode: mode).scaleEffect(0.36).frame(width: 7.2, height: 7.2)
    }

    /// title row of a done card: bold title, dim meta
    static func title(_ title: String, meta: String?) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: text, weight: .semibold)).foregroundStyle(.white)
            if let meta { Text(meta).font(.system(size: text)).foregroundStyle(.white.opacity(0.5)) }
        }
        .lineLimit(1)
    }

    static func words(_ s: String) -> String { HubFormat.words(s.split(whereSeparator: \.isWhitespace).count) }
}

/// Closed notch → recording in the mode colour → done card → folds back. Dictation ends in the
/// compact done card, prompt mode in its card with the structured prompt (plain text, as the
/// island shows it).
struct OnboardingMiniIsland: View {
    enum Beat { case closed, recording, card }

    let mode: Mode
    /// nil until the loop starts (renders never run it and show the characteristic beat)
    @State private var beat: Beat?
    /// true while recording ↔ card swap inside the surface; false for entering / leaving
    @State private var swapping = false
    @Environment(\.hubStatic) private var isStatic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var dictation: String { L("Morgen um zehn mit Lena die Folien durchgehen.") }
    static var prompt: [String] { [L("Rolle: Lektor"), L("Aufgabe: Mail an Lena kürzen"), L("Format: drei Sätze")] }

    private var current: Beat { isStatic ? (mode == .prompt ? .card : .recording) : (beat ?? .closed) }

    var body: some View {
        let b = current
        let g = geometry(b)
        ZStack(alignment: .top) {
            HubWallpaper()
            OnboardingMini.hardwareNotch()
            ZStack(alignment: .top) {
                NotchSurfaceShape()
                content(b)
                    .animation(IslandMotion.swap, value: b)
                    .frame(width: g.width, alignment: .top)
                    .mask(alignment: .top) { NotchSurfaceMask() }
            }
            .islandSurface(g, widthGrowing: b != .closed, heightGrowing: b != .closed, reduce: reduceMotion)
        }
        .task {
            // a plain loop: `.task` is cancelled the moment the step leaves (PhaseAnimator kept
            // cycling after its view was gone)
            guard !isStatic else { return }
            while !Task.isCancelled {
                guard await OnboardingLoop.pause(0.7) else { return }
                swapping = false
                beat = .recording
                guard await OnboardingLoop.pause(mode == .prompt ? 2.0 : 2.4) else { return }
                swapping = true
                guard await OnboardingLoop.pause(0.03) else { return }
                beat = .card
                guard await OnboardingLoop.pause(mode == .prompt ? 2.8 : 2.2) else { return }
                swapping = false
                guard await OnboardingLoop.pause(0.03) else { return }
                beat = .closed
                guard await OnboardingLoop.pause(0.7) else { return }
            }
        }
    }

    private func geometry(_ b: Beat) -> IslandSurfaceGeometry {
        switch b {
        case .closed: return OnboardingMini.closed
        case .recording: return IslandSurfaceGeometry(width: 116, height: 17, top: 3, bottom: 6)
        case .card:
            return mode == .prompt
                ? IslandSurfaceGeometry(width: 152, height: 58, top: 4, bottom: 11)
                : IslandSurfaceGeometry(width: 152, height: 41, top: 4, bottom: 10)
        }
    }

    @ViewBuilder private func content(_ b: Beat) -> some View {
        ZStack(alignment: .top) {
            if b == .recording {
                ears.transition(swapping ? .islandSwap(height: 17, reduce: reduceMotion)
                                         : .islandEnter(toward: .center, reduce: reduceMotion))
            }
            if b == .card {
                card.transition(swapping ? .islandSwap(height: 48, reduce: reduceMotion)
                                         : .islandEnter(toward: .top, reduce: reduceMotion))
            }
        }
    }

    private var ears: some View {
        HStack(spacing: 3) {
            Circle().fill(Palette.accent(mode).opacity(0.24))
                .overlay(Image(systemName: "mic.fill").font(.system(size: 4.5, weight: .bold))
                    .foregroundStyle(Palette.accent(mode)))
                .frame(width: 9, height: 9)
            Circle().fill(Palette.rec).frame(width: 3, height: 3)
            Spacer(minLength: 0)
            HubWave(style: .sym, colors: .mode(mode), source: .speech, height: 8, bar: 1.5, gap: 1.1,
                    seed: mode == .prompt ? 0.6 : 0)
        }
        .padding(.horizontal, 7)
        .frame(width: 116, height: 17)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            HStack(spacing: 0) {
                OnboardingMini.check(mode)
                Spacer(minLength: 0)
                if mode == .prompt {
                    Text("⌘V")
                        .font(.system(size: 5.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 2.5)
                        .frame(height: 8)
                        .background(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(.white.opacity(0.16)))
                } else {
                    Text(L("0,4 s")).font(.system(size: 6.5)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(height: OnboardingMini.notch.height)
            if mode == .prompt {
                OnboardingMini.title(L("Prompt in der Zwischenablage"), meta: nil)
                ForEach(Self.prompt, id: \.self) { line in
                    Text(line).font(.system(size: OnboardingMini.text)).foregroundStyle(.white.opacity(0.88))
                }
            } else {
                OnboardingMini.title(L("Eingefügt in Notizen"), meta: OnboardingMini.words(Self.dictation))
                Text(Self.dictation)
                    .font(.system(size: OnboardingMini.text))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .frame(width: 152, alignment: .leading)
    }
}

/// A done card under the notch; the pointer arrives, the same card widens and unfolds the whole
/// text with the copy button, the pointer leaves and it folds back after 0.6 s (SPEC §0 hover).
struct OnboardingMiniHover: View {
    @State private var pointerIn = false
    @State private var over = false
    @Environment(\.hubStatic) private var isStatic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var text: String { L("Morgen um zehn mit Lena die Folien durchgehen. Danach schicke ich die Zahlen ans Team.") }

    var body: some View {
        let o = isStatic || over
        let p = isStatic || pointerIn
        let g = o ? IslandSurfaceGeometry(width: 166, height: 74, top: 4, bottom: 12)
                  : IslandSurfaceGeometry(width: 152, height: 41, top: 4, bottom: 10)
        ZStack(alignment: .top) {
            HubWallpaper()
            OnboardingMini.hardwareNotch()
            ZStack(alignment: .top) {
                NotchSurfaceShape()
                card(o)
                    .animation(IslandMotion.swap, value: o)
                    .frame(width: g.width, alignment: .top)
                    .mask(alignment: .top) { NotchSurfaceMask() }
            }
            .islandSurface(g, widthGrowing: o, heightGrowing: o, reduce: reduceMotion)
            Image(systemName: "cursorarrow")
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 1, y: 0.5)
                .offset(x: p ? 34 : 70, y: p ? 46 : 74)
                .animation(reduceMotion ? IslandMotion.crossFade : .easeInOut(duration: 0.45), value: p)
        }
        .task {
            guard !isStatic else { return }
            while !Task.isCancelled {
                guard await OnboardingLoop.pause(1.0) else { return }
                pointerIn = true
                guard await OnboardingLoop.pause(0.5) else { return }
                over = true
                guard await OnboardingLoop.pause(2.8) else { return }
                pointerIn = false
                guard await OnboardingLoop.pause(0.6) else { return }
                over = false
                guard await OnboardingLoop.pause(0.9) else { return }
            }
        }
    }

    private func card(_ open: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1.5) {
            HStack(spacing: 0) {
                OnboardingMini.check(.dictate)
                Spacer(minLength: 0)
                Text(L("0,7 s")).font(.system(size: 6.5)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(height: OnboardingMini.notch.height)
            OnboardingMini.title(L("Eingefügt in Mail"), meta: OnboardingMini.words(Self.text))
            ZStack(alignment: .topLeading) {
                if open {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.text)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 2) {
                            Image(systemName: "doc.on.doc").font(.system(size: 5, weight: .semibold))
                            Text(L("Kopieren")).font(.system(size: 6, weight: .medium))
                        }
                        .padding(.horizontal, 4)
                        .frame(height: 10)
                        .background(Capsule().fill(.white.opacity(0.14)))
                    }
                    .transition(.islandHandOver(reduce: reduceMotion))
                } else {
                    Text(Self.text).lineLimit(1)
                        .transition(.islandHandOver(reduce: reduceMotion))
                }
            }
            .font(.system(size: OnboardingMini.text))
            .foregroundStyle(.white.opacity(0.88))
        }
        .padding(.horizontal, 7)
        .frame(width: open ? 166 : 152, alignment: .leading)
    }
}

// MARK: - 3 to 5 Permissions

struct OnboardingPermissionStep: View {
    let model: OnboardingModel
    let step: OnboardingModel.Step
    @Environment(\.colorScheme) private var scheme

    private var permission: OnboardingModel.Permission { step.permission ?? .microphone }
    private var grant: OnboardingModel.Grant { model.grants[permission] ?? .missing }
    private var restart: Bool { permission == .inputMonitoring && grant == .granted && model.restartNeeded }
    private var stateKey: String { "\(grant.rawValue)\(restart ? "-restart" : "")" }

    var body: some View {
        let t = HubTheme(scheme)
        OnboardingPage {
            HubSquircle(icon: icon, size: 64)
                .shadow(color: .black.opacity(t.dark ? 0.3 : 0.12), radius: 6, y: 3)
                .padding(.bottom, OnboardingGap.m)
            OnboardingHeader(title: L(step.title), subtitle: sentence)
                .padding(.bottom, OnboardingGap.l)
            // one slot that changes state in place: nothing below it moves
            ZStack {
                slot
                    .id(stateKey)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            .frame(height: 30)
            .padding(.bottom, OnboardingGap.s)
            ZStack(alignment: .top) {
                hint
                    .id(stateKey)
                    .transition(.opacity)
            }
            .frame(width: OnboardingLayout.column, height: 64, alignment: .top)
        }
        .animation(onboardingSpring, value: stateKey)
    }

    private var icon: HubIcon {
        switch permission {
        case .microphone: return HubIcon(symbol: "mic.fill", top: 0xFFB648, bottom: 0xFF8A00)
        case .accessibility: return HubIcon(symbol: "accessibility", top: 0x5AA8FF, bottom: 0x1E6FF0)
        case .inputMonitoring: return HubIcon(symbol: "keyboard.fill", top: 0xA7A7AC, bottom: 0x6E6E73)
        }
    }

    private var sentence: String {
        switch permission {
        case .microphone:
            return L("VoiceBud braucht deine Erlaubnis, um dich zu hören.\nDas Mikrofon läuft nur, während du diktierst.")
        case .accessibility:
            return L("VoiceBud braucht deine Erlaubnis, um Text an deinem Cursor einzufügen\nund zu sehen, in welcher App du schreibst.")
        case .inputMonitoring:
            return L("VoiceBud braucht deine Erlaubnis, um deine\nTastenkürzel in jeder App zu erkennen.")
        }
    }

    @ViewBuilder private var slot: some View {
        HStack(spacing: OnboardingGap.s) {
            if restart {
                OnboardingStatus(mark: .warn, text: L("Wirkt nach Neustart"), large: true)
                Button(L("VoiceBud neu starten")) { model.restartCore() }
                    .buttonStyle(OnboardingButtonStyle(kind: .primary, minWidth: 150))
                    .keyboardShortcut(.defaultAction)
            } else {
                switch grant {
                case .missing:
                    Button(L("Freigabe erteilen")) { model.request(permission) }
                        .buttonStyle(OnboardingButtonStyle(kind: .primary, minWidth: 150))
                        .keyboardShortcut(.defaultAction)
                case .requested:
                    if permission == .microphone {
                        OnboardingStatus(mark: .busy, text: L("Wartet auf deine Antwort"), large: true)
                    } else {
                        OnboardingStatus(mark: .busy, text: L("Wartet auf deinen Schalter"), large: true)
                        settingsButton
                    }
                case .denied:
                    OnboardingStatus(mark: .warn, text: L("Abgelehnt"), large: true)
                    settingsButton
                case .granted:
                    OnboardingStatus(mark: .ok, text: L("Erteilt"), large: true)
                }
            }
        }
        .fixedSize()
    }

    private var settingsButton: some View {
        Button(L("Systemeinstellungen öffnen")) { model.openSettings(permission) }
            .buttonStyle(OnboardingButtonStyle(kind: .secondary, minWidth: 150))
    }

    /// What to press in Apple's dialog and what to switch on, under the name macOS really shows.
    private var lines: [String] {
        let name = model.tccName
        let asApp = name == "VoiceBud"
        let quoted = L("„%@“", name)
        let alias = asApp ? "" : "\n" + L("Unter diesem Namen läuft VoiceBud im Hintergrund.")
        let restartNote = L("Danach startest du VoiceBud einmal neu, mit einem Klick hier.")
        let openAndSwitch = L("Klick im Dialog auf „Systemeinstellungen öffnen“ und schalte dort %@ ein.", quoted) + alias
        let switchOn = L("Schalte in den Systemeinstellungen %@ ein.", quoted) + alias
        switch permission {
        case .microphone:
            switch grant {
            case .granted: return [L("Weiter geht’s mit den Bedienungshilfen.")]
            case .denied: return [L("Schalte in den Systemeinstellungen unter „Mikrofon“ den Eintrag %@ ein.", quoted) + alias]
            case .missing, .requested:
                return asApp
                    ? [L("macOS fragt gleich, ob VoiceBud dein Mikrofon nutzen darf.\nWähle „Erlauben“.")]
                    : [L("macOS fragt gleich, ob %@ dein Mikrofon nutzen darf.\nDas ist VoiceBud, wähle „Erlauben“.", quoted)]
            }
        case .accessibility:
            switch grant {
            case .granted: return [L("Weiter geht’s mit der Eingabeüberwachung.")]
            case .missing: return [openAndSwitch]
            case .requested, .denied:
                return [switchOn,
                        L("Steht %@ nicht in der Liste? Klick auf [Im Finder zeigen](voicebud://reveal) und zieh die Datei hinein.", quoted)]
            }
        case .inputMonitoring:
            if restart {
                return [L("Die Freigabe greift erst, wenn VoiceBud neu startet.\nDas dauert zwei Sekunden, dieses Fenster bleibt offen.")]
            }
            switch grant {
            case .granted: return [L("Weiter geht’s mit den Modellen.")]
            case .missing: return [openAndSwitch, restartNote]
            case .requested, .denied: return [switchOn, restartNote]
            }
        }
    }

    private var hint: some View {
        VStack(spacing: OnboardingGap.xs) {
            ForEach(lines, id: \.self) { line in
                OnboardingRichText(text: line, model: model)
            }
        }
        .font(OnboardingType.secondary)
        .foregroundStyle(HubTheme(scheme).prose)
        .multilineTextAlignment(.center)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 6 Modelle

struct OnboardingModels: View {
    let model: OnboardingModel

    private var note: String {
        if model.models.contains(where: { if case .paused = $0.phase { return true }; return false }) {
            return L("Keine Verbindung zum Internet.\nDer Download geht weiter, sobald du wieder online bist.")
        }
        if model.models.contains(where: { if case .downloading = $0.phase { return true }; return false }) {
            return L("Du musst nicht warten, der Download läuft im Hintergrund.")
        }
        return L("Beide Modelle sind da. Ab jetzt braucht VoiceBud kein Internet mehr.")
    }

    var body: some View {
        OnboardingPage {
            OnboardingHeader(title: L("Modelle"),
                             subtitle: L("Spracherkennung und Textaufbereitung laufen lokal.\nDie Modelle werden einmal geladen und bleiben auf deinem Mac."))
                .padding(.bottom, OnboardingGap.l)
            VStack(alignment: .leading, spacing: 0) {
                HubCard {
                    ForEach(Array(model.models.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { HubSeparator() }
                        OnboardingModelRow(item: item) { model.retryDownload(item.id) }
                    }
                }
                OnboardingFootnote(note, lines: 2)
            }
            .frame(width: OnboardingLayout.column)
        }
    }
}

struct OnboardingModelRow: View {
    let item: OnboardingModel.ModelItem
    var retry: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    private var speech: Bool { item.id == "whisper" }

    private var icon: HubIcon {
        speech
            ? HubIcon(symbol: "waveform", top: 0xC3A8FF, bottom: 0x8F6CF2)
            : HubIcon(symbol: "text.alignleft", top: 0x5EEAD4, bottom: 0x14B8A6)
    }

    /// the progress bar takes the row icon's colour
    private func tint(_ t: HubTheme) -> Color {
        speech ? t.modeDot(.dictate) : t.modeDot(.prompt)
    }

    var body: some View {
        let t = HubTheme(scheme)
        VStack(spacing: 0) {
            HStack(spacing: OnboardingGap.s) {
                HubSquircle(icon: icon, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(item.role)).font(OnboardingType.body).foregroundStyle(t.fg)
                    Text(L(item.name)).font(OnboardingType.secondary).foregroundStyle(t.prose)
                }
                Spacer(minLength: OnboardingGap.s)
                trailing(t)
            }
            switch item.phase {
            case .downloading(let got, let total):
                OnboardingProgressBar(fraction: total > 0 ? got / total : 0, tint: tint(t))
                    .padding(.leading, 40)
                    .padding(.top, 10)
            case .paused(let got, let total):
                OnboardingProgressBar(fraction: total > 0 ? got / total : 0, tint: t.fg3)
                    .padding(.leading, 40)
                    .padding(.top, 10)
            case .ready:
                EmptyView()
            }
        }
        .padding(.horizontal, OnboardingGap.s)
        .padding(.vertical, 10)
    }

    @ViewBuilder private func trailing(_ t: HubTheme) -> some View {
        switch item.phase {
        case .ready:
            HStack(spacing: OnboardingGap.s) {
                Text(OnboardingFormat.gb(item.sizeGB))
                    .font(OnboardingType.secondary.monospacedDigit())
                    .foregroundStyle(t.prose)
                OnboardingStatus(mark: .ok, text: L("Bereit"))
            }
        case .downloading(let got, let total):
            Text(L("%@ von %@", OnboardingFormat.gbValue(got / 1000), OnboardingFormat.gb(total / 1000)))
                .font(OnboardingType.secondary.monospacedDigit())
                .foregroundStyle(t.prose)
                .contentTransition(.numericText())
        case .paused:
            HStack(spacing: OnboardingGap.s) {
                OnboardingStatus(mark: .warn, text: L("Pausiert"))
                HubChip(title: L("Erneut versuchen"), symbol: "arrow.clockwise", action: retry)
            }
        }
    }
}

struct OnboardingProgressBar: View {
    let fraction: Double
    var tint: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(t.trackOff)
                Capsule().fill(tint).frame(width: max(4, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

enum OnboardingFormat {
    /// "0,9 GB" (English "0.9 GB")
    static func gb(_ v: Double) -> String { gbValue(v) + " GB" }
    /// "1,1" (English "1.1")
    static func gbValue(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return Loc.shared.english ? s : s.replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - 7 Probediktat

struct OnboardingTestDictation: View {
    let model: OnboardingModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.hubStatic) private var isStatic

    private var listening: Bool { model.test == .listening }

    var body: some View {
        let t = HubTheme(scheme)
        let keys = HubFormat.hotkey(model.hotkeys["dictate"] ?? "ctrl+shift")
        OnboardingPage {
            OnboardingHeader(title: L("Probediktat"),
                             subtitle: L("Drück beide Tasten, sag einen Satz und drück sie noch einmal."))
                .padding(.bottom, OnboardingGap.l)
            OnboardingBigKeys(keys: keys, pressed: listening,
                              action: model.mock && !isStatic ? { model.simulateTest() } : nil)
                .padding(.bottom, OnboardingGap.l)
            VStack(alignment: .leading, spacing: 0) {
                HubCard {
                    resultArea(t)
                        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                        .padding(.horizontal, OnboardingGap.m)
                        .padding(.vertical, 14)
                    HubSeparator()
                    statusRow(t)
                        .padding(.horizontal, OnboardingGap.s)
                        .frame(height: 44)
                }
                OnboardingFootnote(footnote, lines: 2, model: model)
                    .transaction { $0.animation = nil }
            }
            .frame(width: OnboardingLayout.column)
        }
        .task(id: listening) {
            // silent microphone: no signal 3 s after VoiceBud started listening
            guard listening, !model.mock, !isStatic else { return }
            model.resetPeak()
            guard await OnboardingLoop.pause(3) else { return }
            if model.peakLevel < 0.08 { model.flatSignal = true }
        }
    }

    private var footnote: String {
        model.flatSignal
            ? L("Bleiben die Balken flach, kommt bei VoiceBud kein Ton an.\nWähl in den [Ton-Einstellungen](voicebud://sound) unter „Eingabe“ ein anderes Mikrofon.")
            : L("Im Alltag landet der Text direkt an deinem Cursor, egal in welcher App.")
    }

    @ViewBuilder private func resultArea(_ t: HubTheme) -> some View {
        switch model.test {
        case .result(let text, _):
            // the dictated sentence: content, shown at reading size like the island's text
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(t.fg)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .listening:
            HStack(spacing: OnboardingGap.s) {
                OnboardingLevelBars(levels: model.micLevels, synthetic: model.mock)
                Text(L("Ich höre zu")).font(.system(size: 15)).foregroundStyle(t.prose)
            }
        case .working:
            HStack(spacing: OnboardingGap.s) {
                OnboardingSpinner(size: 14)
                Text(L("Wird erkannt")).font(.system(size: 15)).foregroundStyle(t.prose)
            }
        case .ready:
            // placeholder, deliberately lighter than real copy
            Text(L("Hier erscheint dein Text."))
                .font(.system(size: 15))
                .foregroundStyle(t.fg3)
        }
    }

    @ViewBuilder private func statusRow(_ t: HubTheme) -> some View {
        HStack(spacing: OnboardingGap.xs) {
            switch model.test {
            case .result(let text, let seconds):
                HStack(spacing: 7) {
                    IslandCheckBadge(mode: .dictate).scaleEffect(0.8).frame(width: 16, height: 16)
                    Text(L("in %@ erkannt", HubFormat.seconds(seconds)))
                        .font(OnboardingType.secondaryMedium)
                        .foregroundStyle(t.fg)
                    Text(HubFormat.words(text.split(whereSeparator: \.isWhitespace).count))
                        .font(OnboardingType.secondary)
                        .foregroundStyle(t.prose)
                        .padding(.leading, 4)
                }
                Spacer(minLength: OnboardingGap.xs)
                HubChip(title: L("Noch einmal"), symbol: "arrow.clockwise") { model.retryTest() }
            case .listening:
                OnboardingStatus(mark: .rec, text: L("Nimmt auf"))
                Spacer(minLength: OnboardingGap.xs)
                device(t)
            case .working:
                OnboardingStatus(mark: .busy, text: L("Wird erkannt"))
                Spacer(minLength: OnboardingGap.xs)
                device(t)
            case .ready:
                OnboardingStatus(mark: .idle, text: L("Wartet auf dein Diktat"))
                Spacer(minLength: OnboardingGap.xs)
                device(t)
            }
        }
    }

    private func device(_ t: HubTheme) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "mic").font(.system(size: 11, weight: .medium))
            Text(model.micDevice).font(OnboardingType.secondary)
        }
        .foregroundStyle(t.prose)
    }
}

/// The hotkey as physical keys: symbol glyph (optically centred) with the word printed on the key
/// below it. They light up in the dictation colour while VoiceBud listens.
struct OnboardingBigKeys: View {
    let keys: [String]
    var pressed = false
    /// mock window only: press to play a scripted take
    var action: (() -> Void)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let action {
                Button(action: action) { caps }.buttonStyle(HubPlainStyle())
            } else {
                caps
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L("Tastenkürzel %@", keys.map(OnboardingKeys.word).joined(separator: L(" und "))))
    }

    private var caps: some View {
        let t = HubTheme(scheme)
        return HStack(spacing: OnboardingGap.s) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                VStack(spacing: 5) {
                    OnboardingKeys.glyph(k, size: 19, weight: .regular)
                        .frame(height: 22)
                    if !OnboardingKeys.word(k).isEmpty {
                        Text(OnboardingKeys.word(k))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(pressed ? Color.white.opacity(0.85) : t.prose)
                    }
                }
                .foregroundStyle(pressed ? Color.white : t.fg)
                .frame(width: 62, height: 56)
                .background(shape.fill(pressed ? t.accent : (t.dark ? Color(hex: 0x3A3A3D) : Color.white)))
                .overlay(shape.strokeBorder(t.dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1), lineWidth: 0.5))
                .background(shape.fill(Color.black.opacity(t.dark ? 0.5 : 0.13)).offset(y: pressed ? 1 : 2.5))
                .offset(y: pressed ? 1.5 : 0)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
    }
}

/// Seven level bars in the dictation colour, fed by the core's `level` bands (or calm synthetic
/// speech in the mock window).
struct OnboardingLevelBars: View {
    let levels: [Float]
    var synthetic = false
    @Environment(\.hubStatic) private var isStatic

    static let still: [Float] = [0.30, 0.55, 0.82, 1.0, 0.74, 0.5, 0.26]

    var body: some View {
        Group {
            if isStatic {
                bars(Self.still)
            } else if synthetic {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    bars(Self.synthetic(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)))
                }
            } else {
                bars(levels)
                    .animation(.interpolatingSpring(mass: 1, stiffness: 220, damping: 24), value: levels)
            }
        }
        .frame(height: 26)
    }

    private func bars(_ v: [Float]) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { i in
                let level = CGFloat(i < v.count ? min(max(v[i], 0), 1) : 0)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.accent(.dictate), Palette.accentLo(.dictate)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 4, height: 4 + level * 22)
            }
        }
    }

    static func synthetic(_ t: Double) -> [Float] {
        (0..<7).map { i in
            let h = HubWaveMath.bar(i, of: 7, t: t, source: .speech, sym: true, max: 1, min: 0)
            return Float(min(1, h * 1.25))
        }
    }
}

// MARK: - 8 Darstellung

struct OnboardingAppearance: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingPage {
            OnboardingHeader(title: L("Darstellung"), subtitle: L("So zeigt sich VoiceBud, während du sprichst."))
                .padding(.bottom, OnboardingGap.l)
            VStack(alignment: .leading, spacing: 0) {
                // the hub's live stage: island and capsule morph with every choice
                HubIslandStage(shape: model.islandShape, liveText: false, wave: .sym, waveLive: true)
                    .padding(.bottom, OnboardingGap.s)
                HubCard {
                    OnboardingTilePicker(
                        options: [OnboardingTileOption(value: IslandStyle.insel, title: L("Insel an der Notch")),
                                  OnboardingTileOption(value: IslandStyle.kapsel, title: L("Kapsel"))],
                        selection: model.islandShape,
                        select: { v in model.islandShape = v; model.choicesChanged() }) { style in
                        HubIslandTile(style: style, wave: .sym)
                    }
                }
                OnboardingFootnote(L("Live-Text beim Sprechen kannst du später in den Einstellungen einschalten."))
            }
            .frame(width: OnboardingLayout.column)
        }
    }
}

// MARK: - 9 Alcove (only when Alcove is installed)

struct OnboardingAlcove: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingPage {
            OnboardingHeader(title: "Alcove", subtitle: L("Alcove nutzt die Notch auch.\nWähle, wie sich die beiden die Notch teilen."))
                .padding(.bottom, OnboardingGap.l)
            VStack(alignment: .leading, spacing: 0) {
                HubCard {
                    OnboardingTilePicker(
                        options: [OnboardingTileOption(value: OnboardingModel.AlcoveChoice.dodge, title: L("Ausweichen")),
                                  OnboardingTileOption(value: .auto, title: L("Automatisch"), badge: L("Empfohlen")),
                                  OnboardingTileOption(value: .takeover, title: L("Übernehmen"))],
                        selection: model.alcove, tileHeight: 64,
                        select: { v in model.alcove = v; model.choicesChanged() }) { choice in
                        OnboardingAlcoveTile(choice: choice)
                    }
                }
                OnboardingFootnote(note, lines: 2)
                    .transaction { $0.animation = nil }
            }
            .frame(width: OnboardingLayout.column)
        }
    }

    private var note: String {
        switch model.alcove {
        case .dodge: return L("Alcove behält die Notch. VoiceBud erscheint als Kapsel direkt darunter.")
        case .auto: return L("VoiceBud sitzt in der Notch, solange Alcove nichts zeigt.\nSpielt Alcove etwas ab, rutscht VoiceBud darunter.")
        case .takeover: return L("Während du diktierst, gehört die Notch VoiceBud.")
        }
    }
}

struct OnboardingAlcoveTile: View {
    let choice: OnboardingModel.AlcoveChoice

    var body: some View {
        switch choice {
        case .dodge: HubAlcoveTile(mode: .dodge)
        case .takeover: HubAlcoveTile(mode: .takeover)
        case .auto:
            // VoiceBud in the notch; the capsule it moves into when Alcove plays something, faint
            ZStack(alignment: .top) {
                HubWallpaper()
                HubIslandShape(ear: 3, bottom: 5)
                    .fill(Color.black)
                    .frame(width: 80, height: 12)
                    .overlay {
                        HStack(spacing: 0) {
                            Circle().fill(Palette.rec).frame(width: 3.5, height: 3.5)
                            Spacer(minLength: 0)
                            HubWave(style: .sym, height: 6, bar: 1.2, gap: 0.9)
                        }
                        .padding(.horizontal, 8)
                    }
                HStack(spacing: 4) {
                    Circle().fill(Palette.rec).frame(width: 3.5, height: 3.5)
                    HubWave(style: .sym, height: 6, bar: 1.2, gap: 0.9)
                }
                .padding(.horizontal, 8)
                .frame(height: 14)
                .background(Capsule().fill(Color.black))
                .opacity(0.35)
                .padding(.top, 18)
            }
        }
    }
}

// MARK: - 10 Mitlesen

struct OnboardingContext: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingPage {
            OnboardingHeader(title: L("Mitlesen"),
                             subtitle: L("VoiceBud liest mit, damit Namen und Fachbegriffe stimmen.\nDu entscheidest, wie viel."))
                .padding(.bottom, OnboardingGap.l)
            VStack(alignment: .leading, spacing: 0) {
                HubCard {
                    OnboardingTilePicker(
                        options: [OnboardingTileOption(value: OnboardingModel.ContextLevel.app, title: L("Nur die App"),
                                                       detail: L("Weiß nur, in welcher\nApp du schreibst.")),
                                  OnboardingTileOption(value: .cursor, title: L("Text am Cursor"),
                                                       detail: L("Liest die Zeilen rund\num deinen Cursor."), badge: L("Empfohlen")),
                                  OnboardingTileOption(value: .window, title: L("Ganzes Fenster"),
                                                       detail: L("Liest das ganze\naktive Fenster."))],
                        selection: model.context, tileHeight: 86,
                        select: { v in model.context = v; model.choicesChanged() }) { level in
                        OnboardingContextTile(level: level)
                    }
                }
                HubCard {
                    HubRow(L("Im Prompt-Modus „diese Mail“ dazusagen"),
                           subtitle: L("Dann liest VoiceBud für dieses eine Diktat das ganze Fenster\nund hängt den Text wörtlich unter den Prompt.")) {
                        EmptyView()
                    }
                }
                .padding(.top, OnboardingGap.m)
                OnboardingFootnote(L("Passwortfelder liest VoiceBud nie.\nDer Kontext wird nicht gespeichert und verlässt deinen Mac nicht."), lines: 2)
            }
            .frame(width: OnboardingLayout.column)
        }
    }
}

/// A Mail compose window under the menu bar; violet marks what VoiceBud reads at this level:
/// the app name in the menu bar, the lines around the cursor, or the whole window.
struct OnboardingContextTile: View {
    let level: OnboardingModel.ContextLevel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let ink = dark ? Color.white.opacity(0.9) : Color.black.opacity(0.82)
        let dim = dark ? Color.white.opacity(0.5) : Color.black.opacity(0.48)
        let rule = dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08)
        let win = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack(alignment: .top) {
            HubWallpaper(light: !dark)
            menuBar(ink: dark ? .white.opacity(0.92) : .black.opacity(0.85))
            VStack(alignment: .leading, spacing: 0) {
                titleBar(dim: dim)
                VStack(alignment: .leading, spacing: 0) {
                    header(L("An:"), "Lena", ink: ink, dim: dim)
                    rule.frame(height: 0.5)
                    header(L("Betreff:"), L("Folien für morgen"), ink: ink, dim: dim)
                    rule.frame(height: 0.5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Hallo Lena, schickst du mir die Folien"))
                        HStack(spacing: 0.5) {
                            Text(L("für morgen bis zehn?"))
                            Rectangle().fill(Color(hex: 0x8F6CF2)).frame(width: 0.8, height: 7)
                        }
                    }
                    .font(.system(size: 6.5))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background { if level == .cursor { highlight } }
                    .padding(.top, 3)
                    .padding(.horizontal, -3)
                }
                .padding(.horizontal, 7)
                .padding(.top, 1)
                .padding(.bottom, 5)
                .background {
                    if level == .window { highlight.padding(.horizontal, 3).padding(.bottom, 2) }
                }
            }
            .frame(width: 142, alignment: .topLeading)
            .background(win.fill(dark ? Color(hex: 0x2C2C2E) : Color.white))
            .overlay(win.strokeBorder(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1.5)
            .padding(.top, 15)
        }
    }

    private var highlight: some View {
        let mark = Color(hex: 0x8F6CF2)
        return RoundedRectangle(cornerRadius: 3, style: .continuous).fill(mark.opacity(0.2))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(mark, lineWidth: 1))
    }

    /// the frontmost app's name sits in the menu bar, as on the real Mac
    private func menuBar(ink: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "apple.logo").font(.system(size: 6.5))
            Text("Mail").font(.system(size: 6.5, weight: .bold))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background { if level == .app { highlight } }
                .padding(.horizontal, -3)
            Text(L("Ablage")).font(.system(size: 6.5))
            Text(L("Bearbeiten")).font(.system(size: 6.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 9)
        .frame(height: 11)
        .background(scheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.4))
    }

    private func titleBar(dim: Color) -> some View {
        ZStack {
            HStack(spacing: 2.5) {
                Circle().fill(Color(hex: 0xFF5F57)).frame(width: 4, height: 4)
                Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 4, height: 4)
                Circle().fill(Color(hex: 0x28C840)).frame(width: 4, height: 4)
                Spacer(minLength: 0)
            }
            Text(L("Folien für morgen")).font(.system(size: 5.5, weight: .semibold)).foregroundStyle(dim)
        }
        .padding(.horizontal, 5)
        .frame(height: 11)
    }

    private func header(_ label: String, _ value: String, ink: Color, dim: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(dim)
            Text(value).foregroundStyle(ink)
        }
        .font(.system(size: 6.5))
        .frame(height: 9.5)
    }
}

// MARK: - 11 Alles bereit

/// Texterkennung: what ⇧⌘2 does, and the Screen Recording permission (optional: it can also be
/// given at the first ⇧⌘2). macOS reports the permission only after a restart, so there is no live
/// status here; the setup restarts VoiceBud at the end when it was asked for.
struct OnboardingScreenText: View {
    let model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var stateKey: String { model.screenTextGranted ? "granted" : model.screenTextAsked ? "asked" : "missing" }

    var body: some View {
        let t = HubTheme(scheme)
        OnboardingPage {
            HubSquircle(icon: HubIcon(symbol: "text.viewfinder", top: 0x8CCBFF, bottom: 0x3E92F0), size: 64)
                .shadow(color: .black.opacity(t.dark ? 0.3 : 0.12), radius: 6, y: 3)
                .padding(.bottom, OnboardingGap.m)
            OnboardingHeader(title: L("Texterkennung"),
                             subtitle: L("Drück ⇧⌘2 und zieh einen Bereich auf. VoiceBud liest den Text darin,\nTabellen bleiben Tabellen, alles landet in der Zwischenablage."))
                .padding(.bottom, OnboardingGap.l)
            ZStack {
                slot.id(stateKey).transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            .frame(height: 30)
            .padding(.bottom, OnboardingGap.s)
            ZStack(alignment: .top) {
                hint.id(stateKey).transition(.opacity)
            }
            .frame(width: OnboardingLayout.column, height: 64, alignment: .top)
        }
        .animation(onboardingSpring, value: stateKey)
    }

    /// centred like the hint under the other permission steps
    private var hint: some View {
        Text(note)
            .font(OnboardingType.secondary)
            .foregroundStyle(HubTheme(scheme).prose)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var slot: some View {
        HStack(spacing: OnboardingGap.s) {
            if model.screenTextGranted {
                OnboardingStatus(mark: .ok, text: L("Erteilt"), large: true)
            } else if model.screenTextAsked {
                OnboardingStatus(mark: .warn, text: L("Wirkt nach dem Neustart am Ende"), large: true)
                Button(L("Systemeinstellungen öffnen")) { model.requestScreenText() }
                    .buttonStyle(OnboardingButtonStyle(kind: .secondary, minWidth: 150))
            } else {
                Button(L("Bildschirmaufnahme erlauben")) { model.requestScreenText() }
                    .buttonStyle(OnboardingButtonStyle(kind: .primary, minWidth: 190))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize()
    }

    private var note: String {
        if model.screenTextAsked && !model.screenTextGranted {
            // the permission belongs to the UI, not the core: outside the app bundle macOS lists it
            // under the launcher's name, not tccName, so only the bundled name is spelled out
            let where_ = model.tccName == "VoiceBud" ? L("in den Systemeinstellungen „VoiceBud“") : L("VoiceBud in den Systemeinstellungen")
            return L("Schalte %@ ein.\nDie Freigabe greift nach dem Neustart, den VoiceBud am Ende macht.", where_)
        }
        let privacy = L("Das Bild bleibt auf deinem Mac und wird gleich gelöscht, der Text kommt in den Verlauf.")
        return model.screenTextGranted ? privacy : L("Optional, geht auch später beim ersten ⇧⌘2.") + "\n" + privacy
    }
}

struct OnboardingFinish: View {
    let model: OnboardingModel
    @State private var icon = OnboardingAppIcon.load()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        OnboardingPage {
            appIcon
                .padding(.bottom, OnboardingGap.s)
            Text(L("Alles bereit"))
                .font(OnboardingType.title)
                .foregroundStyle(t.fg)
                .padding(.bottom, OnboardingGap.xs)
            OnboardingKeyLine(before: L("Drück"), keys: HubFormat.hotkey(model.hotkeys["dictate"] ?? "ctrl+shift"),
                              after: L("in einer beliebigen App und sprich los."))
                .padding(.bottom, OnboardingGap.m)
            HubCard {
                OnboardingRow(L("Beim Anmelden starten"), subtitle: L("VoiceBud wartet dann still in der Menüleiste.")) {
                    HubSwitch(isOn: Binding(get: { model.launchAtLogin },
                                            set: { model.launchAtLogin = $0; model.choicesChanged() }))
                }
                HubSeparator()
                OnboardingRow(L("VoiceBud lernt mit"), subtitle: L("Verbesserte Wörter merkt sich VoiceBud.")) {
                    Image(systemName: "book.closed.fill").font(.system(size: 15)).foregroundStyle(Color(hex: 0xF59E0B))
                }
                HubSeparator()
                OnboardingRow(L("Kürzel"), subtitle: L("Aus „meine Signatur“ wird der ganze Text.")) {
                    Image(systemName: "text.badge.plus").font(.system(size: 15)).foregroundStyle(Color(hex: 0x22C55E))
                }
                HubSeparator()
                OnboardingRow(L("Texterkennung"), subtitle: L("⇧⌘2 drücken und einen Bereich aufziehen.")) {
                    Image(systemName: "text.viewfinder").font(.system(size: 15)).foregroundStyle(Color(hex: 0x3E92F0))
                }
                HubSeparator()
                OnboardingRow(L("Verlauf und Einstellungen"), subtitle: L("Klick auf das Mikrofon in der Menüleiste.")) {
                    OnboardingMenuBarTip()
                }
            }
            .frame(width: OnboardingLayout.narrow)
        }
    }

    @ViewBuilder private var appIcon: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .overlay(alignment: .bottomTrailing) {
                    IslandCheckBadge(mode: .dictate)
                        .scaleEffect(1.05)
                        .frame(width: 21, height: 21)
                        .background(Circle().fill(HubTheme(scheme).windowBg).padding(-3))
                        .offset(x: -4, y: -4)
                }
        } else {
            IslandCheckBadge(mode: .dictate).scaleEffect(2.6).frame(width: 64, height: 64)
        }
    }
}

/// A slice of the menu bar with VoiceBud's microphone ringed.
struct OnboardingMenuBarTip: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let fg = dark ? Color.white.opacity(0.9) : Color.black.opacity(0.82)
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 18)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fg.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .strokeBorder(HubTheme(scheme).ring, lineWidth: 1.6).padding(-2.5))
            Image(systemName: "wifi").font(.system(size: 11, weight: .semibold))
            Text("9:41").font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045)))
    }
}
