// VoiceBudUI entry point: accessory app with the menu-bar item, owns island + hub.
//   (no args)       normal mode, driven by the Python core over stdin/stdout
//   --render <dir>  write PNGs of every island state and hub pane, then exit
//   --demo          scripted loop recording → processing → done, no stdin needed
//   env VOICEBUD_UI_HEADLESS=1  process everything, but never put a window on screen
import AppKit
import SwiftUI

IPC.protectStdout()

enum CoreFlags {
    static let arguments = CommandLine.arguments
    static let demo = arguments.contains("--demo")
    static let headless = ProcessInfo.processInfo.environment["VOICEBUD_UI_HEADLESS"] == "1"
}

// SCRATCH (onboarding): --render-onboarding <dir> writes every step as PNG plus a contact sheet;
// --onboarding opens the real window with mock state (closes the app when the window closes).
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

// SCRATCH: --onboarding-selftest <dir> (run with VOICEBUD_UI_HEADLESS=1): builds the real window
// through OnboardingController without putting it on screen, captures every step and the hero
// loop with cacheDisplay, closes it and checks that window, model and hero are released.
if let i = CoreFlags.arguments.firstIndex(of: "--onboarding-selftest") {
    let dir = URL(fileURLWithPath: CoreFlags.arguments[i + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
            + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            @MainActor func capture(_ w: NSWindow, _ name: String) {
                if ProcessInfo.processInfo.environment["VB_NOCAPTURE"] != nil { return }
                guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
                    IPC.log("selftest: no rep for \(name)"); return
                }
                v.cacheDisplay(in: v.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("live-\(name).png"))
                }
            }
            try? await Task.sleep(for: .seconds(1))
            let cold = footprintMB()
            // warm-up: the real helper always has SwiftUI loaded (island, hub); render a hidden
            // island window once so the numbers below show what the onboarding itself adds
            @MainActor func warmUp() {
                let state = AppState()
                let island = IslandModel()
                island.presented = true
                island.phase = .recording
                let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.contentViewController = NSHostingController(rootView: IslandView(state: state, model: island))
                w.displayIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { w.close(); w.contentViewController = nil }
            }
            warmUp()
            try? await Task.sleep(for: .seconds(2))
            let before = footprintMB()
            IPC.log(String(format: "selftest: footprint cold %.1f MB, after SwiftUI warm-up %.1f MB", cold, before))
            var controller: OnboardingController? = OnboardingController()
            controller?.show()
            weak var weakModel: OnboardingModel?
            weak var weakWindow: NSWindow?
            weak var weakHost: NSViewController?
            weak var weakHostView: NSView?
            // grabbed in a synchronous helper, so no strong temporary survives in this async frame
            @MainActor func grab(_ c: OnboardingController?) {
                weakModel = c?.model
                weakWindow = c?.currentWindow
                weakHost = c?.currentWindow?.contentViewController
                weakHostView = c?.currentWindow?.contentView
            }
            grab(controller)
            // the window and the model live only inside this function, so after close nothing in
            // the test keeps them alive
            @MainActor func drive(_ c: OnboardingController) async -> Double {
                guard let w = c.currentWindow, let m = c.model else { IPC.log("selftest: no window"); exit(1) }
                var t = 0.0
                let heroShots: [(Double, String)] = ProcessInfo.processInfo.environment["VB_FROM"] != nil ? [] :
                    [(0.3, "a-zu"), (1.05, "b-waechst"), (2.2, "c-aufnahme"), (4.2, "d-spinner"),
                     (6.0, "e-fertig"), (8.95, "f-klappt-zurueck")]
                for (at, label) in heroShots {
                    try? await Task.sleep(for: .seconds(at - t)); t = at
                    capture(w, "01-hero-\(label)")
                }
                let open = footprintMB()
                let from = Int(ProcessInfo.processInfo.environment["VB_FROM"] ?? "2") ?? 2
                for step in m.steps.dropFirst() where step.rawValue + 1 >= from {
                    m.go(to: step)
                    try? await Task.sleep(for: .seconds(1.2))
                    let window = Double(ProcessInfo.processInfo.environment["VB_CPUWIN"] ?? "1.0") ?? 1.0
                    let c0 = cpuSeconds()
                    try? await Task.sleep(for: .seconds(window))
                    IPC.log(String(format: "selftest: step %d CPU %.1f %% (%.0f s average)", step.rawValue + 1,
                                   (cpuSeconds() - c0) / window * 100, window))
                    capture(w, "\(OnboardingRenderer.number(step))-\(OnboardingRenderer.slug(step))")
                    // live state changes: the slot morphs in place, the take shows the level bars
                    if step == .accessibility {
                        m.request(.accessibility)
                        try? await Task.sleep(for: .seconds(0.8))
                        capture(w, "04b-bedienungshilfen-wartet")
                    }
                    if step == .testDictation {
                        m.simulateTest()
                        try? await Task.sleep(for: .seconds(1.0))
                        capture(w, "07b-probediktat-hoert-zu")
                        try? await Task.sleep(for: .seconds(2.8))
                        capture(w, "07c-probediktat-ergebnis")
                    }
                    // step 2: film the mini previews mid-loop (recording, card, hover)
                    if step == .howItWorks {
                        for (wait, label) in [(1.6, "a"), (0.35, "b"), (1.45, "c"), (1.0, "d")] {
                            try? await Task.sleep(for: .seconds(wait))
                            capture(w, "02-so-funktionierts-\(label)")
                        }
                    }
                }
                return open
            }
            let open = await drive(controller!)
            let cpuOpen0 = cpuSeconds()
            try? await Task.sleep(for: .seconds(3))
            let cpuOpen = (cpuSeconds() - cpuOpen0) / 3 * 100
            controller?.close()
            controller = nil
            try? await Task.sleep(for: .seconds(2))
            let cpu0 = cpuSeconds()
            try? await Task.sleep(for: .seconds(5))
            let cpuIdle = (cpuSeconds() - cpu0) / 5 * 100
            let after = footprintMB()
            IPC.log(String(format: "selftest: footprint before %.1f MB, open %.1f MB, after close %.1f MB", before, open, after))
            IPC.log(String(format: "selftest: CPU while open (step 11) %.1f %%, after close %.2f %%", cpuOpen, cpuIdle))
            IPC.log("selftest: model released \(weakModel == nil), window released \(weakWindow == nil)")
            // the NSWindow shell itself stays referenced by AppKit's titlebar widgets
            // (_NSCoreHostingView<ThemeWidgetView> in SwiftUI's shared graph host, traced with
            // `leaks --traceTree`); nothing of ours points at it any more
            try? await Task.sleep(for: .seconds(ProcessInfo.processInfo.environment["VB_HOLD"] != nil ? 30 : 4))
            IPC.log("selftest: 4 s later window released \(weakWindow == nil), host released \(weakHost == nil), host view released \(weakHostView == nil)")
            exit(weakModel == nil ? 0 : 3)
        }
    }
    NSApplication.shared.run()
}

// SCRATCH: --onboarding-logic checks the model's flow rules without any window: step lists with
// and without Alcove, the quiet "Weiter", permission states, the scripted take, the IPC calls.
if CoreFlags.arguments.contains("--onboarding-logic") {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            var fails = 0
            func check(_ ok: Bool, _ what: String) {
                if !ok { fails += 1 }
                IPC.log((ok ? "ok    " : "FAIL  ") + what)
            }
            func tick() async { try? await Task.sleep(for: .milliseconds(30)) }
            var calls: [String] = []
            let m = OnboardingModel()
            m.actions.watchPermissions = { calls.append("watch \($0)") }
            m.actions.micLevels = { calls.append("levels \($0)") }
            m.actions.requestPermission = { calls.append("request \($0.rawValue)") }
            m.alcoveInstalled = true
            check(m.steps.count == 11 && m.steps.contains(.alcove), "11 steps with Alcove")
            m.alcoveInstalled = false
            check(m.steps.count == 10 && !m.steps.contains(.alcove), "10 steps without Alcove")
            m.go(to: .appearance); await tick()
            m.next(); await tick()
            check(m.step == .context, "without Alcove, Darstellung goes straight to Mitlesen")
            m.alcoveInstalled = true
            m.back(); await tick()
            check(m.step == .alcove, "with Alcove, back from Mitlesen lands on Alcove")
            m.go(to: .microphone); await tick()
            check(calls.contains("watch true"), "entering a permission step starts permission polling")
            check(!m.advanceIsPrimary && m.advanceTitle == "Weiter", "Weiter stays quiet until the mic is granted")
            m.request(.microphone)
            check(m.grants[.microphone] == .requested && calls.contains("request microphone"), "Freigabe erteilen asks the core")
            m.grants[.microphone] = .granted
            check(m.advanceIsPrimary, "granted mic makes Weiter primary")
            m.go(to: .inputMonitoring); await tick()
            m.grants[.inputMonitoring] = .granted
            m.restartNeeded = true
            check(!m.advanceIsPrimary, "input monitoring waiting for the restart keeps Weiter quiet")
            m.restartNeeded = false
            m.go(to: .testDictation); await tick()
            check(calls.contains("watch false") && calls.contains("levels true"), "test step stops polling and starts levels")
            m.test = .ready
            check(m.advanceTitle == "Überspringen" && !m.advanceIsPrimary, "test step offers a quiet Überspringen")
            m.simulateTest()
            check(m.test == .listening, "mock take starts listening")
            try? await Task.sleep(for: .seconds(3.6))
            check(m.testDone && m.advanceTitle == "Weiter" && m.advanceIsPrimary, "mock take ends with a result and a primary Weiter")
            m.retryTest()
            m.simulateTest()
            m.leave()
            try? await Task.sleep(for: .seconds(3.6))
            check(m.test == .listening && calls.last == "levels false", "closing the window cancels the take and the levels")
            m.resetPeak()
            m.receiveLevels([0.01, 0.02, 0.03, 0.02, 0.01, 0, 0])
            check(m.peakLevel < 0.08, "silent levels stay under the flat threshold")
            m.receiveLevels([0.1, 0.4, 0.6, 0.3, 0.1, 0, 0])
            check(m.peakLevel >= 0.08, "speech levels lift the peak")
            var finished = false
            m.actions.finish = { finished = true }
            m.go(to: .finish); await tick()
            check(m.advanceTitle == "Los geht’s" && m.isLast, "last step says Los geht’s")
            m.next()
            check(finished, "Los geht’s calls finish")
            check(OnboardingHero.done.words == 8, "hero card counts 8 words")
            IPC.log(fails == 0 ? "onboarding logic: all checks passed" : "onboarding logic: \(fails) failed")
            exit(fails == 0 ? 0 : 1)
        }
    }
    NSApplication.shared.run()
}

if CoreFlags.arguments.contains("--onboarding") {
    let controller = MainActor.assumeIsolated { () -> OnboardingController in
        let c = OnboardingController()
        c.onClose = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) } }
        return c
    }
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { MainActor.assumeIsolated { controller.show() } }
    }
    NSApplication.shared.run()
    exit(0)
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
    private var demo: DemoDriver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CoreFlags.headless { HeadlessWindows.install() }
        if let icon = Self.appIcon() { NSApp.applicationIconImage = icon }

        state = AppState()
        island = IslandController(state: state)
        hub = HubController(state: state)

        buildMenu()
        if !CoreFlags.headless { buildStatusItem() }

        if CoreFlags.demo {
            IPC.attach(state: state, island: island, hub: hub)
        } else {
            IPC.start(state: state, island: island, hub: hub)
        }
        IPC.send(["type": "ready"])

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
        updateHints()
        menu.addItem(dictateHint)
        menu.addItem(promptHint)
        menu.addItem(.separator())

        let hubItem = NSMenuItem(title: "Verlauf & Einstellungen …", action: #selector(showHub), keyEquivalent: ",")
        hubItem.target = self
        menu.addItem(hubItem)
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
    }

    @objc private func showHub() { hub.show() }

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
            dir.appendingPathComponent("AppIcon.icns"),
            dir.appendingPathComponent("../../assets/AppIcon.icns").standardizedFileURL,
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }
}

// MARK: - Hotkey display

enum HotkeyFormat {
    /// "ctrl+shift" → "⌃⇧", "alt_r" → "⌥ rechts", "f13" → "F13" (macOS modifier order ⌃⌥⇧⌘).
    static func display(_ spec: String) -> String {
        let order = ["ctrl": 0, "alt": 1, "shift": 2, "cmd": 3]
        let glyph = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘"]
        var parts: [(rank: Int, text: String, sided: Bool)] = []
        for raw in spec.lowercased().split(separator: "+") {
            let name = raw.trimmingCharacters(in: .whitespaces)
            let side = name.hasSuffix("_l") ? " links" : name.hasSuffix("_r") ? " rechts" : ""
            let base = side.isEmpty ? name : String(name.dropLast(2))
            if let g = glyph[base] {
                parts.append((order[base] ?? 9, g + side, !side.isEmpty))
            } else {
                parts.append((10, name.uppercased(), false))
            }
        }
        parts.sort { $0.rank < $1.rank }
        let separator = parts.contains { $0.sided } ? " " : ""
        return parts.map(\.text).joined(separator: separator)
    }
}

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
