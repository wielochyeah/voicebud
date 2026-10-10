// Shortcuts with a regular key (10.10.): the text recognition's ⇧⌘2 and any key the user chose in the
// hub for dictation, prompt or command (⌃W, ⌃⌥D, F5). They are registered here with macOS (Carbon
// hot keys), so the key never reaches the app in front, and every press and release of the three
// dictation shortcuts goes to the core, which decides what it means (toggle or hold, see
// hotkey.KeyHotkey). Shortcuts of modifiers alone (⌃⇧, ⌘ right) are the core's own.
import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private static let signature = OSType(0x5642_5554)          // "VBUT"
    private static let ids: [String: UInt32] = ["dictate": 1, "ocr": 2, "prompt": 3, "command": 4]

    private weak var state: AppState?
    private var refs: [String: EventHotKeyRef] = [:]
    private var registered: [String: KeyCombo] = [:]
    /// keys whose exclusive registration failed: another app holds them (they get no presses)
    private(set) var heldElsewhere: Set<String> = []
    /// why a key could not be registered at all (macOS status, e.g. -9868: ⌥ alone on macOS 15.0/15.1)
    private(set) var failed: [String: OSStatus] = [:]
    /// keys down right now: macOS sends a release only to the registration that got the press, so a
    /// mode taken away while held gets its release from here (a held take would never end otherwise)
    private var held: Set<String> = []
    /// the hub records a new shortcut: none of them may fire meanwhile
    private var paused = false
    private var installed = false

    func start(state: AppState) {
        self.state = state
        if !installed {
            installed = true
            var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                            nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard got == noErr, id.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
                let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                let which = id.id
                DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.shared.fired(which, down: down) } }
                return noErr
            }, 2, &specs, nil, nil)
        }
        apply()
    }

    /// the key a mode holds right now (nil: a chord, off, or paused)
    func combo(_ mode: String) -> KeyCombo? { registered[mode] }

    /// what the settings ask for: each mode with a key shortcut, the recognition only while it is on
    func apply() {
        guard let state, !CoreFlags.headless else { return }
        let s = state.settings
        var want: [String: KeyCombo] = [:]
        if !paused {
            // the core's order; a mode the core does not have (no prompt in config.yaml) gets no key,
            // and a key twice inside VoiceBud goes to the first mode only
            for mode in ["dictate", "prompt", "command", "ocr"] {
                let shortcut: Shortcut?
                if mode == "ocr" {
                    shortcut = s.screenText ? s.ocrShortcut : nil
                } else {
                    shortcut = state.hotkeys[mode] != nil ? s.shortcuts[mode] : nil
                }
                guard case .key(let k)? = shortcut else { continue }
                if let first = want.first(where: { $0.value.key == k.key && $0.value.mods == k.mods }) {
                    IPC.log("hotkeys: \(mode) \(k.label) is already \(first.key)'s, not registered twice")
                    continue
                }
                want[mode] = k
            }
        }
        for (mode, combo) in registered where want[mode] != combo {
            if held.remove(mode) != nil && mode != "ocr" {
                IPC.send(["type": "hotkey", "mode": mode, "down": false])
            }
            if let ref = refs[mode] { UnregisterEventHotKey(ref) }
            refs[mode] = nil
            registered[mode] = nil
            heldElsewhere.remove(mode)
            IPC.log("hotkeys: \(mode) \(combo.label) released")
        }
        for mode in failed.keys where want[mode] == nil { failed[mode] = nil }
        heldElsewhere = heldElsewhere.filter { want[$0] != nil }
        for (mode, combo) in want where registered[mode] == nil {
            register(mode, combo)
        }
    }

    func pause(_ on: Bool) {
        paused = on
        apply()
    }

    /// exclusive: another app on the same keys stays silent while VoiceBud holds them, instead of
    /// both acting. A plain hot key never fails, so only the exclusive call can tell that someone else
    /// got there first (it is then registered plainly, and gets presses once the other lets go).
    private func register(_ mode: String, _ combo: KeyCombo) {
        guard let number = Self.ids[mode] else { return }
        let id = EventHotKeyID(signature: Self.signature, id: number)
        var ref: EventHotKeyRef?
        var status = RegisterEventHotKey(combo.key, combo.mods, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr {
            refs[mode] = ref
            registered[mode] = combo
            failed[mode] = nil
            heldElsewhere.remove(mode)
            IPC.log("hotkeys: \(mode) \(combo.label) ready")
            return
        }
        if status != OSStatus(eventHotKeyExistsErr) {
            // not a holder but a refusal (-9868: ⌥ or ⌥⇧ alone on macOS 15.0 and 15.1)
            failed[mode] = status
            IPC.log("hotkeys: \(mode) \(combo.label) refused by macOS (status \(status))")
            return
        }
        status = RegisterEventHotKey(combo.key, combo.mods, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs[mode] = ref
            registered[mode] = combo
            heldElsewhere.insert(mode)
        } else {
            failed[mode] = status
        }
        IPC.log("hotkeys: \(mode) \(combo.label) is held exclusively by another app, VoiceBud gets no presses (status \(status))")
    }

    /// what macOS says to a key right now, without keeping it (the recognition's key while it is
    /// switched off): nil when it could be registered, else the status (-9878: another app holds it)
    func probe(_ combo: KeyCombo) -> OSStatus? {
        let id = EventHotKeyID(signature: Self.signature, id: 9)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.key, combo.mods, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr ? nil : status
    }

    private func fired(_ number: UInt32, down: Bool) {
        guard !paused, let mode = Self.ids.first(where: { $0.value == number })?.key, registered[mode] != nil else { return }
        if down { held.insert(mode) } else if held.remove(mode) == nil { return }   // a release without its press
        if mode == "ocr" {
            if down { ScreenText.shared?.pressed() }
        } else {
            IPC.send(["type": "hotkey", "mode": mode, "down": down])
        }
    }
}
