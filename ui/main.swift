// VoiceBudUI entry point: accessory app with the menu-bar item, owns island + hub.
//   (no args)       normal mode, driven by the Python core over stdin/stdout
//   --render <dir>  write PNGs of every island state and hub pane, then exit
//   --demo          scripted loop recording → processing → done, no stdin needed
//   env VOICEBUD_UI_HEADLESS=1  process everything, but never put a window on screen
import AppKit

// Texterkennung helper: a separate short-lived process (see OCRHelper.swift); before anything
// touches stdout, which is its reply channel
if CommandLine.arguments.contains("--ocr-helper") { OCRHelper.run() }
// Screen Recording, asked by a fresh process: the long-running UI keeps the answer it got at
// launch, a new process sees a permission granted since (ScreenText.freshAccess)
if CommandLine.arguments.contains("--screen-access") {
    print(CGPreflightScreenCaptureAccess() ? "1" : "0")
    exit(0)
}

IPC.protectStdout()

enum CoreFlags {
    static let arguments = CommandLine.arguments
    static let demo = arguments.contains("--demo")
    static let headless = ProcessInfo.processInfo.environment["VOICEBUD_UI_HEADLESS"] == "1"
}

// --render-onboarding-window <png> (VOICEBUD_UI_HEADLESS=1): the REAL onboarding window, titlebar
// and safe area included, drawn off screen (the step stills above skip the window chrome)
if let i = CoreFlags.arguments.firstIndex(of: "--render-onboarding-window"), i + 1 < CoreFlags.arguments.count {
    let out = URL(fileURLWithPath: CoreFlags.arguments[i + 1])
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let c = OnboardingController(makeModel: {
            let m = OnboardingModel()
            m.rendering = true
            m.step = .finish
            return m
        })
        c.show()
        if let view = c.currentWindow?.contentView {
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
                IPC.log("window \(view.bounds.size), safe area top \(view.safeAreaInsets.top) -> \(out.path)")
            }
        }
    }
    exit(0)
}

if let i = CoreFlags.arguments.firstIndex(of: "--render-onboarding") {
    guard i + 1 < CoreFlags.arguments.count else {
        IPC.log("usage: VoiceBudUI --render-onboarding <dir>")
        exit(2)
    }
    let dir = URL(fileURLWithPath: CoreFlags.arguments[i + 1], isDirectory: true)
    let code: Int32 = MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try renderOnboarding(to: dir)
            IPC.log("onboarding rendered to \(dir.path)")
            return 0
        } catch {
            IPC.log("onboarding render failed: \(error)")
            return 1
        }
    }
    exit(code)
}

if let i = CoreFlags.arguments.firstIndex(of: "--render") {
    guard i + 1 < CoreFlags.arguments.count else {
        IPC.log("usage: VoiceBudUI --render <dir>")
        exit(2)
    }
    let dir = URL(fileURLWithPath: CoreFlags.arguments[i + 1], isDirectory: true)
    let code: Int32 = MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try renderIslandStates(to: dir)
            try renderHubPanes(to: dir)
            IPC.log("rendered to \(dir.path)")
            return 0
        } catch {
            IPC.log("render failed: \(error)")
            return 1
        }
    }
    exit(code)
}

// MARK: - App delegate

@MainActor
final class CoreAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var state: AppState!
    private var island: IslandController!
    private var hub: HubController!
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let dictateHint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let promptHint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let commandHint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var demo: DemoDriver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CoreFlags.headless { HeadlessWindows.install() }
        if let icon = Self.appIcon() { NSApp.applicationIconImage = icon }

        state = AppState()
        island = IslandController(state: state)
        OnboardingBridge.install(state: state)
        OutputMute.recoverAfterCrash()
        hub = HubController(state: state)

        buildMenu()
        if !CoreFlags.headless { buildStatusItem() }

        if CoreFlags.demo {
            IPC.attach(state: state, island: island, hub: hub)
        } else {
            IPC.start(state: state, island: island, hub: hub)
        }
        IPC.send(["type": "ready"])
        if !CoreFlags.headless && !CoreFlags.demo {
            ScreenText.shared = ScreenText(state: state)
            ScreenText.shared?.start()
        }

        if CoreFlags.demo {
            demo = DemoDriver()
            demo?.start()
        }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "VoiceBud")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "VoiceBud"
        }
        item.menu = menu
        statusItem = item
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        dictateHint.isEnabled = false
        promptHint.isEnabled = false
        commandHint.isEnabled = false
        updateHints()
        menu.addItem(dictateHint)
        menu.addItem(promptHint)
        menu.addItem(commandHint)
        menu.addItem(.separator())

        let hubItem = NSMenuItem(title: "Verlauf & Einstellungen …", action: #selector(showHub), keyEquivalent: ",")
        hubItem.target = self
        menu.addItem(hubItem)
        // hidden: holding ⌥ turns the row above into the Kontext-Probe (KONTEXT-PLAN.md)
        let probeItem = NSMenuItem(title: "Kontext-Probe", action: #selector(contextProbe), keyEquivalent: ",")
        probeItem.keyEquivalentModifierMask = [.command, .option]
        probeItem.isAlternate = true
        probeItem.target = self
        menu.addItem(probeItem)
        let setupItem = NSMenuItem(title: "Einrichtung …", action: #selector(showOnboarding), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "VoiceBud beenden", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Hotkeys arrive with `hello`; the hint rows are refreshed whenever the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) { updateHints() }

    private func updateHints() {
        let keys = state?.hotkeys ?? [:]
        dictateHint.title = "Diktat: " + HotkeyFormat.display(keys["dictate"] ?? "ctrl+shift")
        promptHint.title = "Prompt: " + HotkeyFormat.display(keys["prompt"] ?? "ctrl+alt")
        commandHint.title = "Befehl (halten): " + HotkeyFormat.display(keys["command"] ?? "ctrl+cmd")
        commandHint.isHidden = keys["command"] == nil
    }

    @objc private func showHub() { hub.show() }

    func applicationWillTerminate(_ notification: Notification) { OutputMute.end() }
    @objc private func contextProbe() { IPC.send(["type": "probe"]) }
    @objc private func showOnboarding() { OnboardingBridge.show() }

    @objc private func quit() {
        IPC.sendQuitOnce()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    /// Every standard quit (Dock "Beenden" while the hub is open, logout, a quit Apple Event,
    /// NSRunningApplication.terminate()) passes here. Python must hear about it, otherwise it
    /// takes the exit for a crash, respawns the UI and later keeps running without any UI.
    /// After stdin EOF (Python is gone) nothing is sent.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        IPC.sendQuitOnce()
        return .terminateNow
    }

    /// AppIcon.icns sits next to the binary inside VoiceBud.app (Contents/Resources) and in
    /// assets/ during development; it gives the Dock entry an icon while the hub is open.
    private static func appIcon() -> NSImage? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let dir = exe.deletingLastPathComponent()
        let candidates = [
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? dir.appendingPathComponent("AppIcon.icns"),
            dir.appendingPathComponent("AppIcon.icns"),
            dir.appendingPathComponent("../../assets/AppIcon.icns").standardizedFileURL,
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            // one 512 px representation, not all ten up to 1024 px (that kept ~8 MB decoded)
            guard let full = NSImage(contentsOf: url) else { continue }
            let reps = full.representations
            guard let pick = reps.first(where: { $0.pixelsWide == 512 }) ?? reps.max(by: { $0.pixelsWide < $1.pixelsWide })
            else { return full }
            let small = NSImage(size: NSSize(width: 256, height: 256))
            small.addRepresentation(pick)
            return small
        }
        return nil
    }
}

// MARK: - Hotkey display



// MARK: - Headless (automated tests)

/// Turns every "put this window on screen" call into a no-op, so tests can drive the real
/// island and hub code without anything appearing. Ordering a window OUT still works.
enum HeadlessWindows {
    static func install() {
        let pairs: [(Selector, Selector)] = [
            (#selector(NSWindow.orderFront(_:)), #selector(NSWindow.vbHeadless_orderFront(_:))),
            (#selector(NSWindow.orderBack(_:)), #selector(NSWindow.vbHeadless_orderBack(_:))),
            (#selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.vbHeadless_makeKeyAndOrderFront(_:))),
            (#selector(NSWindow.orderFrontRegardless), #selector(NSWindow.vbHeadless_orderFrontRegardless)),
            (#selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.vbHeadless_order(_:relativeTo:))),
            (NSSelectorFromString("setIsVisible:"), #selector(NSWindow.vbHeadless_setIsVisible(_:))),
        ]
        for (original, replacement) in pairs {
            guard let a = class_getInstanceMethod(NSWindow.self, original),
                  let b = class_getInstanceMethod(NSWindow.self, replacement) else {
                IPC.log("headless: cannot swizzle \(original)")
                continue
            }
            method_exchangeImplementations(a, b)
        }
        IPC.log("headless mode: windows are never shown")
    }
}

extension NSWindow {
    @objc func vbHeadless_orderFront(_ sender: Any?) {}
    @objc func vbHeadless_orderBack(_ sender: Any?) {}
    @objc func vbHeadless_makeKeyAndOrderFront(_ sender: Any?) {}
    @objc func vbHeadless_orderFrontRegardless() {}
    @objc func vbHeadless_order(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        // after the exchange this name points at the original implementation
        if place == .out { vbHeadless_order(place, relativeTo: other) }
    }
    @objc func vbHeadless_setIsVisible(_ flag: Bool) {
        if !flag { vbHeadless_setIsVisible(flag) }
    }
}

// MARK: - Demo loop

/// Plays scripted takes through the same message path the Python core uses (IPC.apply).
@MainActor
final class DemoDriver {
    private struct Take {
        let mode: String
        let text: String
        let outcome: String          // "pasted" | "clipboard" | "empty" | "error"
        let app: String
        let seconds: Double
    }

    private let takes: [Take] = [
        Take(mode: "dictate",
             text: "Hallo Frau Berger, danke für die schnelle Rückmeldung. Ich schicke Ihnen die überarbeitete Fassung bis Freitag und melde mich, sobald das Team die Zahlen geprüft hat.",
             outcome: "pasted", app: "Mail", seconds: 0.7),
        Take(mode: "prompt",
             text: "Fass mir die drei wichtigsten Punkte aus dem Meeting zusammen, als kurze Liste, ohne Floskeln, und markier offene Fragen.",
             outcome: "clipboard", app: "Notizen", seconds: 1.1),
        Take(mode: "dictate", text: "", outcome: "empty", app: "", seconds: 0),
        Take(mode: "dictate", text: "Kurzer Test", outcome: "error", app: "", seconds: 0),
    ]
    private var index = 0
    private var levelTimer: Timer?
    private var t0 = Date()

    func start() { run(takes[0]) }

    private func send(_ msg: [String: Any]) { IPC.apply(msg) }

    private func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(body) }
    }

    private func run(_ take: Take) {
        let words = take.text.split(separator: " ").map(String.init)
        let wordInterval = 0.32
        let speaking = take.outcome == "empty" ? 1.2 : max(1.4, Double(words.count) * wordInterval + 0.5)

        send(["type": "state", "phase": "recording", "mode": take.mode])
        startLevels(silent: take.outcome == "empty")

        if take.outcome != "error" {
            for n in words.indices {
                after(0.45 + Double(n) * wordInterval) { [weak self] in
                    self?.send(["type": "partial", "text": words[0...n].joined(separator: " ")])
                }
            }
        }

        after(speaking) { [weak self] in
            guard let self else { return }
            self.stopLevels()
            self.send(["type": "state", "phase": "processing", "mode": take.mode])
            let processing = take.outcome == "empty" ? 0.4 : 1.2
            self.after(processing) { [weak self] in self?.finish(take, words: words.count) }
        }
    }

    private func finish(_ take: Take, words: Int) {
        var hold = 1.0
        switch take.outcome {
        case "empty":
            send(["type": "state", "phase": "empty", "mode": take.mode])
            hold = 0.8
        case "error":
            send(["type": "state", "phase": "error", "mode": take.mode,
                  "message": "Mikrofon nicht verfügbar"])
            hold = 2.5
        default:
            send(["type": "state", "phase": "done", "mode": take.mode, "app": take.app, "words": words,
                  "seconds": take.seconds, "preview": take.text, "target": take.outcome])
            send(["type": "history_changed"])
            hold = (IPC.state?.settings.confirmSeconds ?? 1.5)
        }
        after(hold + 0.3) { [weak self] in
            guard let self else { return }
            self.send(["type": "state", "phase": "idle"])
            self.index = (self.index + 1) % self.takes.count
            let next = self.takes[self.index]
            self.after(1.6) { [weak self] in self?.run(next) }
        }
    }

    /// ~30 Hz synthetic levels: syllable rhythm (~4.5 Hz) under phrase gaps, energy weighted
    /// towards the low-mid bands like real speech. Calm on purpose.
    private func startLevels(silent: Bool) {
        t0 = Date()
        let shape: [Double] = [0.55, 0.85, 1.0, 0.9, 0.7, 0.5, 0.35]
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = Date().timeIntervalSince(self.t0)
                let syllable = pow(max(0, sin(2 * .pi * 4.5 * t)), 1.4)
                let phrase = t.truncatingRemainder(dividingBy: 2.3) > 1.95 ? 0.08 : 1.0
                let env = silent ? 0.0 : (0.35 + 0.65 * syllable) * phrase * min(1, t * 3)
                let bands = shape.indices.map { i -> Double in
                    let wobble = 0.8 + 0.2 * sin(t * 6.1 + Double(i) * 1.3)
                    return min(1, max(0, env * shape[i] * wobble + 0.02 * Double.random(in: 0...1)))
                }
                self.send(["type": "level", "bands": bands, "rms": env * 0.6])
            }
        }
    }

    private func stopLevels() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}

// MARK: - Run

let coreDelegate = MainActor.assumeIsolated { CoreAppDelegate() }
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = coreDelegate
    app.setActivationPolicy(.accessory)
}
NSApplication.shared.run()
