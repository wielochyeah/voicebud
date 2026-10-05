// JSON-lines bridge to the Python core (SPEC §2).
// stdin  -> one reader thread -> main thread -> AppState + island/hub hooks
// stdout -> IPC.send only. Everything else that writes to fd 1 (a stray print) is
//           redirected to stderr by protectStdout(), so the protocol channel stays clean.
import AppKit
import Foundation

enum IPC {
    private static let writeLock = NSLock()
    private static var outFD: Int32 = STDOUT_FILENO
    private static var started = false

    private(set) static weak var state: AppState?
    private(set) static weak var island: IslandController?
    private(set) static weak var hub: HubController?

    private static let flagLock = NSLock()
    nonisolated(unsafe) private static var _parentGone = false
    nonisolated(unsafe) private static var _quitSent = false

    /// true once stdin hit EOF: the parent already went away, so nobody needs a `quit`.
    static var parentGone: Bool {
        flagLock.lock(); defer { flagLock.unlock() }
        return _parentGone
    }

    /// Tells Python to shut everything down, at most once per process (menu item, Dock quit,
    /// logout and `NSRunningApplication.terminate()` all end up here). No-op once stdin closed.
    static func sendQuitOnce() {
        flagLock.lock()
        let send = !_quitSent && !_parentGone
        _quitSent = true
        flagLock.unlock()
        if send { self.send(["type": "quit"]) }
    }

    /// Reads stdin on a background thread and applies every message on the main thread.
    /// stdin EOF means the parent is gone: the app terminates.
    static func start(state: AppState, island: IslandController, hub: HubController) {
        attach(state: state, island: island, hub: hub)
        guard !started else { return }
        started = true
        let reader = Thread {
            // The thread never returns to a run loop, so nothing drains autoreleased objects
            // (bridged strings, Data, JSONSerialization containers) unless each line gets its
            // own pool. Without it the helper grows by every message it ever received.
            while true {
                let more: Bool = autoreleasepool {
                    guard let line = readLine(strippingNewline: true) else { return false }
                    if let msg = decode(line) {
                        DispatchQueue.main.async { MainActor.assumeIsolated { apply(msg) } }
                    }
                    return true
                }
                if !more { break }
            }
            log("stdin closed, terminating")
            flagLock.lock()
            _parentGone = true
            flagLock.unlock()
            DispatchQueue.main.async { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        }
        reader.name = "VoiceBudUI.stdin"
        reader.qualityOfService = .userInteractive
        reader.start()
    }

    /// Wires the targets without reading stdin (used by --demo).
    static func attach(state: AppState, island: IslandController, hub: HubController) {
        self.state = state
        self.island = island
        self.hub = hub
    }

    /// Writes one compact JSON object plus newline to the parent. Thread-safe.
    static func send(_ msg: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(msg),
              var data = try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes])
        else {
            log("send: not JSON-serialisable: \(msg)")
            return
        }
        data.append(0x0A)
        writeLock.lock()
        defer { writeLock.unlock() }
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard var p = buf.baseAddress else { return }
            var left = buf.count
            while left > 0 {
                let n = write(outFD, p, left)
                if n > 0 {
                    p += n
                    left -= n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    log("send: write failed (errno \(errno)), parent gone?")
                    return
                }
            }
        }
    }

    /// Logs to stderr (stdout belongs to the protocol).
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[VoiceBudUI] \(message)\n".utf8))
    }

    /// Call first thing at launch: keeps the real stdout as a private fd for IPC.send and
    /// points fd 1 at stderr, so print() from any file can never corrupt the protocol.
    static func protectStdout() {
        signal(SIGPIPE, SIG_IGN)
        let fd = dup(STDOUT_FILENO)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        outFD = fd
        dup2(STDERR_FILENO, STDOUT_FILENO)
    }

    static func decode(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let msg = obj as? [String: Any], msg["type"] is String
        else {
            log("ignoring malformed line: \(trimmed.prefix(200))")
            return nil
        }
        return msg
    }

    // MARK: - Applying messages (main thread)

    /// env VOICEBUD_UI_TRACE=1: log every applied message (with the resulting state) to stderr.
    /// Off by default; used by the integration tests to prove what reached the UI.
    private static let trace = ProcessInfo.processInfo.environment["VOICEBUD_UI_TRACE"] == "1"
    private static var tracedLevels = 0
    static var tracing: Bool { trace }

    @MainActor
    static func apply(_ msg: [String: Any]) {
        guard let state, let type = msg["type"] as? String else { return }
        applyUntraced(type, msg, state)
        if trace { traceApplied(type, state) }
    }

    @MainActor
    private static func traceApplied(_ type: String, _ state: AppState) {
        switch type {
        case "state":
            var line = "trace state -> phase=\(state.phase.rawValue) mode=\(state.mode.rawValue)"
            if let d = state.done, state.phase == .done {
                line += " app=\(d.app) words=\(d.words) seconds=\(d.seconds) clipboard=\(d.toClipboard)"
                line += " preview=\(d.preview.prefix(60))"
                line += " text=\(d.fullText.count) chars"
            }
            if let e = state.errorMessage { line += " error=\(e)" }
            log(line)
        case "partial":
            log("trace partial -> \(state.partialText.count) chars, tail: \(state.partialText.suffix(50))")
        case "level":
            tracedLevels += 1
            if tracedLevels % 30 == 1 {
                let b = state.bands.map { String(format: "%.2f", $0) }.joined(separator: ",")
                log("trace level #\(tracedLevels) -> phase=\(state.phase.rawValue) bands=[\(b)]")
            }
        case "history_changed":
            log("trace history_changed -> historyVersion=\(state.historyVersion)")
        case "hello":
            log("trace hello -> hotkeys=\(state.hotkeys.sorted { $0.key < $1.key })")
        default:
            break
        }
    }

    @MainActor
    private static func applyUntraced(_ type: String, _ msg: [String: Any], _ state: AppState) {
        switch type {
        case "hello":
            if let keys = msg["hotkeys"] as? [String: Any] {
                for (k, v) in keys { if let s = v as? String { state.hotkeys[k] = s } }
            }
        case "state":
            applyState(msg, to: state)
            OnboardingBridge.take(state)
        case "level":
            var bands = (msg["bands"] as? [Any] ?? []).prefix(7).map { clamp(($0 as? NSNumber)?.floatValue ?? 0) }
            while bands.count < 7 { bands.append(0) }
            OnboardingBridge.level(bands)              // the mic test runs without a recording
            guard state.phase == .recording else { return }
            if msg["bands"] != nil { state.bands = bands }
            if let rms = (msg["rms"] as? NSNumber)?.floatValue { state.rms = clamp(rms) }
            island?.ensureVisibleWhileRecording()
        case "partial":
            guard state.phase == .recording || state.phase == .processing,
                  let text = msg["text"] as? String else { return }
            if text != state.partialText { state.partialText = text }
        case "prepare":
            island?.prepare()                      // a take is about to start (AlcoveSight)
        case "history_changed":
            state.historyVersion += 1
            hub?.historyDidChange()
        case "dictionary_changed":
            hub?.dictionaryDidChange()
        case "onboarding":
            if (msg["show"] as? Bool) == true { OnboardingBridge.show() }
        case "onboarding_state":
            OnboardingBridge.apply(msg)
        case "_test_pointer":
            // headless tests only: a virtual pointer on / off the confirmation card, since a
            // headless panel is never on screen for the real pointer to reach
            guard CoreFlags.headless else { return log("ignoring _test_pointer outside headless mode") }
            island?.testPointer(inside: (msg["inside"] as? Bool) ?? false)
        default:
            log("ignoring unknown message type: \(type)")
        }
    }

    @MainActor
    private static func applyState(_ msg: [String: Any], to state: AppState) {
        guard let raw = msg["phase"] as? String, let phase = Phase(rawValue: raw) else {
            log("state: unknown phase \(msg["phase"] ?? "nil")")
            return
        }
        // the core's late "idle" after a dictation card (3.4 s) must not close the island while
        // the user chooses a region for Texterkennung or it is being read
        if (phase == .idle || phase == .empty), msg["mode"] as? String != "ocr", state.mode == .ocr,
           state.phase == .recording || state.phase == .processing, ScreenText.shared?.isBusy == true {
            ScreenText.shared?.coreState(phase, toClipboard: false)   // (the dictation is over all the same)
            return
        }
        let modeBefore = state.mode
        if let m = (msg["mode"] as? String).flatMap(Mode.init(rawValue:)) { state.mode = m }
        let previous = state.phase

        switch phase {
        case .recording:
            // a dictation started while a region is being chosen is a new take, not more of it
            if previous != .recording || state.mode != modeBefore {
                state.recordingStarted = Date()
                state.partialText = ""
                state.done = nil
                state.bands = Array(repeating: 0, count: 7)
                state.rms = 0
            }
            state.errorMessage = nil
        case .done:
            // "text" (SPEC §0, 03.10.): the whole final text; older cores send only the preview
            let full = (msg["text"] as? String).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
            state.done = DoneInfo(
                app: msg["app"] as? String ?? "",
                words: (msg["words"] as? NSNumber)?.intValue ?? 0,
                seconds: (msg["seconds"] as? NSNumber)?.doubleValue ?? 0,
                preview: msg["preview"] as? String ?? "",
                toClipboard: (msg["target"] as? String) == "clipboard",
                fullText: full,
                context: (msg["context"] as? [String: Any]).map { c in
                    ContextInfo(label: c["label"] as? String ?? "", used: c["used"] as? Bool ?? false,
                                app: c["app"] as? String ?? "", bundle: c["bundle"] as? String ?? "",
                                rows: (c["rows"] as? [[String]]) ?? [], warning: c["warning"] as? String)
                })
            state.errorMessage = nil
        case .error:
            state.errorMessage = (msg["message"] as? String) ?? "Fehler"
        case .processing:
            state.errorMessage = nil
            state.hintAfter = (msg["hint_after"] as? NSNumber)?.doubleValue
        case .idle, .empty:
            state.errorMessage = nil
        }
        state.noticeOK = phase == .error && (msg["tone"] as? String) == "ok"
        if phase != .recording {
            state.bands = Array(repeating: 0, count: 7)
            state.rms = 0
        }
        state.phase = phase
        island?.phaseDidChange()
        MenuBarIcon.shared?.update()
        if msg["mode"] as? String != "ocr" {
            ScreenText.shared?.coreState(phase, toClipboard: state.done?.toClipboard ?? false)
        }
    }

    private static func clamp(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0 }

    /// Runs `body` on the main actor: inline when already on the main thread, else queued.
    static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }
}

// MARK: - Hooks for the hub

extension AppState {
    /// Hub: call after changing `settings`. Writes settings.json (unknown keys kept),
    /// tells Python, and lets the island re-layout. Safe from any thread.
    func commitSettings() {
        IPC.onMain { [self] in
            settings.save()
            IPC.send(["type": "settings_changed"])
            IPC.island?.settingsDidChange()
            ScreenText.shared?.settingsDidChange()
            MenuBarIcon.shared?.update()
        }
    }

    /// Hub: writes snippets.json as {"snippets":[{"trigger","text"}]} and tells Python.
    func commitSnippets(_ items: [[String: String]]) {
        if let data = try? JSONSerialization.data(withJSONObject: ["snippets": items], options: [.prettyPrinted]) {
            do { try data.write(to: Paths.snippets, options: .atomic) } catch {
                IPC.log("snippets.json not written: \(error.localizedDescription)")
            }
        }
        IPC.send(["type": "settings_changed"])
    }

    /// Hub: writes dictionary.json as {"terms":[…]} (other keys kept) and tells Python.
    func commitDictionary(_ terms: [String]) {
        let existing = try? Data(contentsOf: Paths.dictionary)
        let parsed = existing.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if existing != nil && parsed == nil {
            // unreadable file: writing only the terms would drop the learned fixes for good
            IPC.log("dictionary.json cannot be read; not written")
            return
        }
        var root = parsed ?? [:]
        root["terms"] = terms
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            do { try data.write(to: Paths.dictionary, options: .atomic) } catch {
                IPC.log("dictionary.json not written: \(error.localizedDescription)")
            }
        }
        IPC.send(["type": "settings_changed"])
    }
}
