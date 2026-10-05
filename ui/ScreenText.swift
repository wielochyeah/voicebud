// Texterkennung (04.10., replaces TextShot): ⇧⌘2, select a screen region with macOS's own
// crosshair, the text (tables as tables) lands on the clipboard and the island shows it.
//
// The hotkey is a Carbon hot key here in the UI (no permission needed, and the key is swallowed:
// the app in front never sees ⇧⌘2). The recognition runs in a child process (OCRHelper), started
// on the key press so its models load while the user is still dragging, and gone after 2 idle
// minutes; the UI itself stays inside its RAM budget. Needs the Screen Recording permission,
// asked on first use.
import AppKit
import Carbon

@MainActor
final class ScreenText {
    static var shared: ScreenText?

    private let state: AppState
    init(state: AppState) { self.state = state }

    /// a dictation records or is processed: its island and its paste come first (a clipboard
    /// write now could get between the dictation and its Cmd+V)
    private var dictationBusy: Bool {
        (state.phase == .recording || state.phase == .processing) && state.mode != .ocr
    }

    /// choosing a region or recognising it (the core's late "idle" after a dictation card must
    /// not close the island meanwhile, see IPC.applyState)
    var isBusy: Bool { busy }

    private var hotKey: EventHotKeyRef?
    private var helper: Process?
    private var helperIn: FileHandle?
    private var waiting: ((([String: Any]?) -> Void))?
    private var timeoutWork: DispatchWorkItem?
    private var busy = false
    private var capture: Process?              // macOS's crosshair while the user chooses a region
    private var source: NSRunningApplication?  // the app in front when ⇧⌘2 was pressed (for the history)
    private var askedForPermission = false
    private var accessConfirmed = false
    /// the crosshair is out (from the press to the end of the selection)
    private var selecting = false
    private var hintShown = false
    /// a dictation recorded since this ⇧⌘2, and whether its text went to the clipboard
    private var dictationSince = false
    private var dictationOnClipboard = false
    /// a result waiting for that dictation to finish (its island and its paste come first)
    private var pending: (text: String, html: String?, tsv: String?, tables: Int, words: Any, seconds: Double)?
    /// delivers `pending` should the core's idle not come (one at a time: an old one must not cut
    /// a later dictation's card short)
    private var fallback: DispatchWorkItem?

    /// a dictation's island is up: recording, processing, or its card or notice still on screen
    /// (asked of the island: after some notices the core sends no idle, its phase stays .error)
    private var dictationShowing: Bool {
        dictationBusy || IPC.island?.showsDictationCard == true
    }
    private var pendingSince: Date?

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { MainActor.assumeIsolated { ScreenText.shared?.pressed() } }
            return noErr
        }, 1, &spec, nil, nil)
        if state.settings.screenText { register() }
        removeLeftovers()
    }

    /// switched off in the Hub: the shortcut goes back to other apps; on: VoiceBud takes it again
    func settingsDidChange() {
        if state.settings.screenText && hotKey == nil {
            register()
        } else if !state.settings.screenText, let ref = hotKey {
            UnregisterEventHotKey(ref)
            hotKey = nil
            IPC.log("screen text: off, ⇧⌘2 released")
        }
    }

    /// exclusive: another app on ⇧⌘2 (TextShot uses it too) stays silent while VoiceBud holds it,
    /// instead of both taking a picture. A plain hot key never fails, so only the exclusive call
    /// can tell that someone else got there first.
    private func register() {
        let id = EventHotKeyID(signature: OSType(0x5642_5554), id: 2)   // "VBUT"
        var status = RegisterEventHotKey(UInt32(kVK_ANSI_2), UInt32(cmdKey | shiftKey), id,
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        if status == noErr {
            IPC.log("screen text: ⇧⌘2 ready")
            return
        }
        status = RegisterEventHotKey(UInt32(kVK_ANSI_2), UInt32(cmdKey | shiftKey), id,
                                     GetApplicationEventTarget(), 0, &hotKey)
        let other = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "io.fadel.TextShot" }
            ? "TextShot" : "another app"
        // only an exclusive holder makes the exclusive call fail, and it then keeps ⇧⌘2 to itself
        IPC.log("screen text: ⇧⌘2 is held exclusively by \(other), VoiceBud gets no presses (status \(status))")
    }

    /// pictures of a UI that died between the capture and the answer
    private func removeLeftovers() {
        let dir = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix("voicebud-ocr-") && name.hasSuffix(".png") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: flow

    func pressed() {
        if busy {
            // a second ⇧⌘2 while the crosshair is out puts it away, like Esc
            if let c = capture, c.isRunning { c.interrupt() }
            return
        }
        if dictationBusy {
            NSSound.beep()                              // not now; the recording stays as it is
            return
        }
        guard hasAccess() else {
            // macOS asks once with its own dialog; after that, the settings
            if !askedForPermission {
                askedForPermission = true
                _ = CGRequestScreenCaptureAccess()
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            show(["type": "state", "phase": "error", "mode": "ocr",
                  "message": "Bildschirmaufnahme erlauben, dann VoiceBud neu starten"])
            return
        }
        busy = true
        dictationSince = false
        dictationOnClipboard = false
        pending = nil                                 // (an earlier one is in the history, if kept)
        fallback?.cancel()
        fallback = nil
        source = NSWorkspace.shared.frontmostApplication
        ensureHelper()
        send(["op": "warm"])                          // the models load while the user drags
        // "Bereich wählen" in the notch or the capsule, left out of the picture. With Alcove on
        // "Automatisch" which of the two depends on what Alcove shows: VoiceBud looks first, while
        // screencapture's crosshair starts up, and shows the hint at the latest after 0.2 s
        // (05.10.: after a pause the old guess kept the capsule for 1-2 s)
        IPC.island?.excludeFromCapture(true)
        selecting = true
        hintShown = false
        if IPC.island?.prepare(then: { [weak self] in self?.showHint() }) == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated { self?.showHint() }
            }
        } else {
            showHint()
        }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicebud-ocr-\(UUID().uuidString).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-i", "-x", "-o", "-t", "png", path.path]   // region, no sound, no shadow
        capture.terminationHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { ScreenText.shared?.captured(path) } }
        }
        do {
            try capture.run()
            self.capture = capture
        } catch {
            busy = false
            selecting = false
            IPC.island?.excludeFromCapture(false)
            show(["type": "state", "phase": "error", "mode": "ocr", "message": "Bildschirmauswahl nicht verfügbar"])
        }
    }

    /// once per press, and only while the crosshair is still out
    private func showHint() {
        // (a dictation that started meanwhile keeps its island)
        guard selecting, busy, !hintShown, !dictationBusy else { return }
        hintShown = true
        show(["type": "state", "phase": "recording", "mode": "ocr"])
    }

    /// the UI's own answer is the one from its launch; a fresh process sees a permission granted
    /// since, so ⇧⌘2 can work without restarting VoiceBud
    private func hasAccess() -> Bool {
        if accessConfirmed || CGPreflightScreenCaptureAccess() { return true }
        guard let exe = Bundle.main.executableURL else { return false }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--screen-access"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let answer = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        accessConfirmed = answer.hasPrefix("1")
        if accessConfirmed { IPC.log("screen text: permission granted since launch, no restart needed") }
        return accessConfirmed
    }

    private func captured(_ path: URL) {
        capture = nil
        selecting = false
        IPC.island?.excludeFromCapture(false)
        guard FileManager.default.fileExists(atPath: path.path) else {
            busy = false                                // Esc: nothing chosen, the island closes quietly
            if state.mode == .ocr && state.phase == .recording { show(["type": "state", "phase": "idle", "mode": "ocr"]) }
            return
        }
        let t0 = Date()
        // the spinner only where no dictation shows its own island (recording, processing, card)
        if !dictationShowing { show(["type": "state", "phase": "processing", "mode": "ocr"]) }
        request(["op": "ocr", "path": path.path, "lines": Self.keepsLines(source)], timeout: 15) { [weak self] reply in
            try? FileManager.default.removeItem(at: path)
            guard let self else { return }
            self.busy = false
            // a dictation's island is up: nothing over it now (failures stay quiet, a result waits);
            // otherwise the island shows this recognition's spinner, which must always end
            let dictation = self.dictationShowing
            guard let reply else {
                if dictation { return }
                self.show(["type": "state", "phase": "error", "mode": "ocr", "message": "Texterkennung hat nicht geantwortet"])
                return
            }
            let text = (reply["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard reply["ok"] as? Bool == true, !text.isEmpty else {
                if dictation { return }
                let unreadable = reply["error"] as? String == "image"
                self.show(["type": "state", "phase": "error", "mode": "ocr",
                           "message": unreadable ? "Bildausschnitt nicht lesbar" : "Kein Text gefunden"])
                return
            }
            let tables = reply["tables"] as? Int ?? 0
            if self.state.settings.screenTextHistory {
                IPC.send(["type": "ocr_result", "text": text, "app": self.source?.localizedName ?? "",
                          "bundle": self.source?.bundleIdentifier ?? "", "seconds": Date().timeIntervalSince(t0)])
            }
            IPC.log("screen text: \(text.count) chars, \(tables) tables, recognition \(reply["ms"] ?? 0) ms")
            let result = (text: text, html: reply["html"] as? String, tsv: reply["tsv"] as? String, tables: tables,
                          words: reply["words"] ?? 0, seconds: Date().timeIntervalSince(t0))
            self.pending = result
            self.pendingSince = Date()
            if dictation {
                // no clipboard write and no card over the dictation's island now: the result
                // follows its idle (or the fallback)
                IPC.log("screen text: waits for the dictation to finish")
                self.scheduleFallback(5)
                return
            }
            self.deliverPending()
        }
    }

    private func deliver(_ r: (text: String, html: String?, tsv: String?, tables: Int, words: Any, seconds: Double)) {
        publish(r.text, html: r.html, tsv: r.tsv)
        show(["type": "state", "phase": "done", "mode": "ocr",
              "app": r.tables > 0 ? (r.tables == 1 ? "Tabelle erkannt" : "\(r.tables) Tabellen erkannt") : "",
              "words": r.words, "seconds": r.seconds,
              "preview": Self.preview(Self.withoutTableSyntax(r.text)), "target": "clipboard", "text": r.text])
    }

    /// IPC: a state of the core's own (a dictation): remembered while a recognition runs, and the
    /// waiting result goes out when the dictation's card is gone
    func coreState(_ phase: Phase, toClipboard: Bool) {
        if phase == .recording && busy { dictationSince = true }
        if phase == .done && toClipboard && (busy || pending != nil) { dictationOnClipboard = true }
        switch phase {
        case .idle, .empty:
            deliverPending()
        case .done, .error:
            // the core's idle follows the card (3.4 s); should it not come, the result still does
            if pending != nil { scheduleFallback(4) }
        default:
            break
        }
    }

    private func scheduleFallback(_ seconds: Double) {
        fallback?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.deliverPending() } }
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// the result out, unless a dictation's island is still up (then later). A dictation that
    /// came and went and left its text on the clipboard keeps it there: maybe not pasted yet.
    private func deliverPending() {
        guard let p = pending else { return }
        if dictationBusy { return }                       // its done or idle brings us back
        // its card is up (or held by the pointer): wait for it, but not forever (a card set to stay)
        let waited = pendingSince.map { Date().timeIntervalSince($0) } ?? 0
        if dictationShowing && waited < 15 {
            scheduleFallback(1)
            return
        }
        fallback?.cancel()
        fallback = nil
        pending = nil
        defer { dictationSince = false; dictationOnClipboard = false }
        if dictationOnClipboard {
            IPC.log("screen text: not copied, the dictation's text is on the clipboard")
            let kept = state.settings.screenTextHistory
            show(["type": "state", "phase": "error", "mode": "ocr", "tone": kept ? "ok" : "",
                  "message": kept ? "Text im Verlauf, Diktat bleibt in der Ablage" : "Diktat hatte Vorrang, Text nicht kopiert"])
            return
        }
        deliver(p)
    }

    /// Terminal and code editors: lines stay lines (no paragraphs), indentation stays
    static let lineApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "co.zeit.hyper", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.apple.dt.Xcode", "com.sublimetext.4", "com.sublimetext.3", "com.barebones.bbedit", "com.panic.Nova",
        "org.vim.MacVim", "com.neovide.neovide", "com.exafunction.windsurf",
    ]

    static func keepsLines(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return lineApps.contains(id) || id.hasPrefix("com.jetbrains.") || id.hasPrefix("com.google.android.studio")
    }

    /// the island, through the same path as the core's messages
    private func show(_ msg: [String: Any]) {
        IPC.apply(msg)
    }

    // MARK: clipboard

    /// chat apps paste HTML through editors without tables (Claude, ChatGPT, Slack, Teams: the
    /// cells glued into one line, 04.10.), so there the clipboard holds only the plain text, whose
    /// Markdown table they understand
    static let plainOnly: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex", "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2", "com.hnc.Discord", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop", "ai.perplexity.mac",
    ]

    private var last: (text: String, html: String?, tsv: String?)?
    private var lastRich = true
    private var ownChange = 0
    private var watchUntil: Date?
    private var activation: NSObjectProtocol?

    /// written for the app in front, and written again when the user switches between a chat app
    /// and any other while it is still on the clipboard (a deferred pasteboard promise would be
    /// asked once, by Raycast's history right away, and then stay fixed: tried 04.10.)
    private func publish(_ text: String, html: String?, tsv: String?) {
        last = (text, html, tsv)
        write(rich: Self.rich(for: NSWorkspace.shared.frontmostApplication), transient: false)
        if html != nil { watchSwitches() } else { stopWatching() }
    }

    private func stopWatching() {
        if let a = activation { NSWorkspace.shared.notificationCenter.removeObserver(a) }
        activation = nil
        watchUntil = nil
    }

    private static func rich(for app: NSRunningApplication?) -> Bool {
        !(app?.bundleIdentifier.map(plainOnly.contains) ?? false)
    }

    private func write(rich: Bool, transient: Bool) {
        guard let last else { return }
        Self.copy(last.text, html: rich ? last.html : nil, tsv: last.tsv, transient: transient)
        lastRich = rich
        ownChange = NSPasteboard.general.changeCount
    }

    private func watchSwitches() {
        watchUntil = Date().addingTimeInterval(600)
        guard activation == nil else { return }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { ScreenText.shared?.switched(to: app) }
            }
    }

    private func switched(to app: NSRunningApplication?) {
        guard NSPasteboard.general.changeCount == ownChange, let until = watchUntil, Date() < until else {
            // something else was copied since (or ten minutes passed): leave the clipboard alone
            stopWatching()
            return
        }
        let rich = Self.rich(for: app)
        if rich != lastRich { write(rich: rich, transient: true) }
    }

    /// the card's "Kopieren": the whole result again, table included
    func copyLast(_ text: String) -> Bool {
        guard let last, last.text == text else { return false }
        // still on the clipboard as written: nothing to do (a second write would be a second entry
        // in Raycast's history)
        if NSPasteboard.general.changeCount == ownChange { return true }
        publish(last.text, html: last.html, tsv: last.tsv)
        return true
    }

    /// plain text for every target (tables as Markdown: chat apps take only plain text and
    /// understand Markdown); with a table also HTML, so Notizen, Mail, Numbers, Excel and Word
    /// paste a real table, and the tab-separated version under its own type for spreadsheets.
    /// `transient`: a rewrite of the same content, which clipboard histories (Raycast) skip.
    static func copy(_ text: String, html: String?, tsv: String? = nil, transient: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let html { item.setString(html, forType: .html) }
        if let tsv { item.setString(tsv, forType: NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")) }
        item.setString("local.voicebud", forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        if transient { item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) }
        pb.writeObjects([item])
    }

    /// the card's preview line: a Markdown table read as its cells
    static func withoutTableSyntax(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("|") else { return String(line) }
            if l.allSatisfy({ "|-: ".contains($0) }) { return nil }               // | --- | --- |
            return l.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    static func preview(_ text: String, limit: Int = 80) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > limit else { return line }
        let head = String(line.prefix(limit))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: ",;: ")) + " …"
    }

    // MARK: helper process

    private func ensureHelper() {
        if let h = helper, h.isRunning { return }
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--ocr-helper"]
        p.qualityOfService = .userInitiated
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.terminationHandler = { gone in
            DispatchQueue.main.async { MainActor.assumeIsolated { ScreenText.shared?.helperGone(gone) } }
        }
        do { try p.run() } catch { IPC.log("screen text: helper failed to start (\(error))"); return }
        helper = p
        helperIn = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer = buffer.subdata(in: buffer.index(after: nl)..<buffer.endIndex)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    DispatchQueue.main.async { MainActor.assumeIsolated { ScreenText.shared?.received(obj) } }
                }
            }
        }
    }

    /// the helper can end between `isRunning` and the write (its idle exit, a crash in Vision):
    /// the throwing write reports that instead of an uncaught "Broken pipe" exception ending the
    /// whole UI (04.10.); a fresh helper gets the message once more
    private func send(_ msg: [String: Any], retry: Bool = true) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        do {
            try helperIn?.write(contentsOf: data + Data("\n".utf8))
        } catch {
            IPC.log("screen text: helper gone while writing (\(error)), starting a new one")
            helper?.terminate()
            helper = nil
            helperIn = nil
            if retry {
                ensureHelper()
                send(msg, retry: false)
            }
        }
    }

    private func request(_ msg: [String: Any], timeout: TimeInterval, _ done: @escaping ([String: Any]?) -> Void) {
        waiting = done
        ensureHelper()
        send(msg)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let w = self.waiting else { return }
                self.waiting = nil
                self.helper?.terminate()
                w(nil)
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func received(_ obj: [String: Any]) {
        if obj["warm"] != nil { return }
        timeoutWork?.cancel()
        let w = waiting
        waiting = nil
        w?(obj)
    }

    /// only the current helper: one ended on purpose (timeout, broken pipe) reports late, when a
    /// new one may already be running
    private func helperGone(_ gone: Process) {
        guard gone === helper else { return }
        helper = nil
        helperIn = nil
        if let w = waiting {
            waiting = nil
            timeoutWork?.cancel()
            w(nil)
        }
    }
}
