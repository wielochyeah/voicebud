// Connects the onboarding window (Onboarding.swift, the approved design) to the Python core:
// UI → core {"type":"onboarding","action":…}, core → UI {"type":"onboarding_state",…} and
// {"type":"onboarding","show":true}. Levels and take states feed the test dictation step.
import AppKit

@MainActor
enum OnboardingBridge {
    private(set) static var controller: OnboardingController?

    static func install(state: AppState) {
        let c = OnboardingController(makeModel: { makeModel(state: state) })
        c.onClose = {
            // back to a menu bar app unless another VoiceBud window (the hub) is still open;
            // checked a moment later: during windowWillClose the closing window still counts
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated {
                    let open = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
                    if !open {
                        NSApp.setActivationPolicy(.accessory)
                        NSApp.hide(nil)          // the app that was in front gets its focus back
                    }
                }
            }
        }
        c.onBecomeKey = { [weak c] in
            // back from the hub: show what it changed, so the next click here starts from there
            guard let c, let m = c.model else { return }
            read(m, from: state.settings)
            c.currentWindow?.title = L("VoiceBud einrichten")
        }
        controller = c
    }

    /// the choices of the window as last read or written (see choicesChanged)
    private struct Choices {
        let shape: IslandStyle, ui: UILanguage, dictation: DictationLanguage
        let alcove: OnboardingModel.AlcoveChoice, context: OnboardingModel.ContextLevel
        @MainActor init(_ m: OnboardingModel) {
            shape = m.islandShape; ui = m.uiLanguage; dictation = m.dictationLanguage; alcove = m.alcove; context = m.context
        }
    }
    private static var written: Choices?

    private static func read(_ m: OnboardingModel, from s: UISettings) {
        m.islandShape = s.islandStyle == .kapsel ? .kapsel : .insel
        m.uiLanguage = s.uiLanguage
        m.dictationLanguage = s.dictationLanguage
        m.alcove = OnboardingModel.AlcoveChoice(rawValue: s.alcove.rawValue) ?? .auto
        m.context = s.contextLevel <= 1 ? .app : s.contextLevel >= 3 ? .window : .cursor
        written = Choices(m)
    }

    static func show() {
        controller?.show()
        send("status")
    }

    private static func send(_ action: String, _ extra: [String: Any] = [:]) {
        var msg: [String: Any] = ["type": "onboarding", "action": action]
        msg.merge(extra) { $1 }
        IPC.send(msg)
    }

    /// VoiceBud.app around Resources/VoiceBudUI.app (what the user adds in System Settings)
    private static var outerApp: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func makeModel(state: AppState) -> OnboardingModel {
        let m = OnboardingModel()
        m.mock = false
        m.hotkeys = state.hotkeys
        read(m, from: state.settings)
        var a = OnboardingActions()
        a.requestPermission = { p in send("request", ["which": p.rawValue]) }
        a.openSettings = { p in NSWorkspace.shared.open(p.settingsURL) }
        a.watchPermissions = { on in send("watch", ["on": on]) }
        a.revealCore = { NSWorkspace.shared.activateFileViewerSelecting([outerApp]) }
        a.restartCore = { send("restart") }
        a.retryDownload = { id in send("download", ["id": id]) }
        a.openSoundSettings = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
        }
        a.micLevels = { on in send("mic", ["on": on]) }
        a.choicesChanged = { model in
            // writes only what was changed in this window: the hub may have changed other settings
            // since it opened (05.10. review: a later click here put them back)
            let was = written ?? Choices(model)
            if model.islandShape != was.shape { state.settings.islandStyle = model.islandShape == .kapsel ? .kapsel : .insel }
            if model.uiLanguage != was.ui { state.settings.uiLanguage = model.uiLanguage }
            if model.dictationLanguage != was.dictation { state.settings.dictationLanguage = model.dictationLanguage }
            if model.alcove != was.alcove { state.settings.alcove = AlcoveMode(rawValue: model.alcove.rawValue) ?? .auto }
            if model.context != was.context {
                state.settings.contextLevel = model.context == .app ? 1 : model.context == .window ? 3 : 2
            }
            written = Choices(model)
            state.commitSettings()
            controller?.currentWindow?.title = L("VoiceBud einrichten")   // the language may have changed
        }
        a.finish = { [weak m] in
            state.settings.onboardingDone = true
            state.commitSettings()
            send("finish", ["login": m?.launchAtLogin ?? false])
        }
        m.actions = a
        return m
    }

    /// core → UI: permissions, model downloads, restart hint, the TCC name and the mic in use
    static func apply(_ msg: [String: Any]) {
        guard let m = controller?.model else { return }
        if let grants = msg["grants"] as? [String: String] {
            for (key, value) in grants {
                guard let p = OnboardingModel.Permission(rawValue: key),
                      let g = OnboardingModel.Grant(rawValue: value) else { continue }
                if g == .missing && m.grants[p] == .requested { continue }  // macOS has not decided yet
                m.grants[p] = g
            }
        }
        if let restart = msg["restart"] as? Bool { m.restartNeeded = restart }
        if let name = msg["tcc"] as? String, !name.isEmpty { m.tccName = name }
        if let mic = msg["mic"] as? String, !mic.isEmpty { m.micDevice = mic }
        for row in msg["models"] as? [[String: Any]] ?? [] {
            guard let id = row["id"] as? String, let i = m.models.firstIndex(where: { $0.id == id }) else { continue }
            let got = (row["received"] as? NSNumber)?.doubleValue ?? 0
            let total = (row["total"] as? NSNumber)?.doubleValue ?? m.models[i].sizeGB * 1000
            switch row["phase"] as? String {
            case "ready": m.models[i].phase = .ready
            case "downloading": m.models[i].phase = .downloading(receivedMB: got, totalMB: total)
            default: m.models[i].phase = .paused(receivedMB: got, totalMB: total)
            }
        }
    }

    static func level(_ bands: [Float]) {
        guard let m = controller?.model, m.step == .testDictation else { return }
        m.receiveLevels(bands)
    }

    static func take(_ state: AppState) {
        guard let m = controller?.model, m.step == .testDictation else { return }
        switch state.phase {
        case .recording: m.test = .listening
        case .processing: m.test = .working
        case .done: if let d = state.done { m.test = .result(text: d.fullText, seconds: d.seconds) }
        case .empty, .error: m.test = .ready
        default: break
        }
    }
}
