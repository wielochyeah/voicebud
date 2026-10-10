// What a new shortcut may be (10.10., Nils: "zu restriktiv", and every refusal must say why), in
// the order of the research of 10.10. (classes [1]-[28], scratchpad shortcut-rules.json). Allowed:
// modifiers alone (two or more, or one right-hand key alone; the core watches them) and keys with
// modifiers or F-keys (registered with macOS here). Refused, with what the keys do instead: what
// macOS uses (the switched-on system shortcuts are read from macOS itself), what nearly every app or
// the text system needs, what types a character that is needed. Accepted with a note: what is
// switched off in macOS, what common apps or the Terminal use, rarely needed ⌥ characters.
import AppKit
import Carbon.HIToolbox

@MainActor
enum ShortcutRules {
    enum Verdict: Equatable {
        case take(Shortcut, note: String?)
        case refuse(String)
    }

    static let cmd: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096
    static let fnFlag: UInt32 = 0x20000                     // kEventKeyModifierFnMask in the system list

    // MARK: keys

    /// keys that type nothing, by key code (positions are the same on every layout)
    static let specialNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 76: "⌤", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦",
        119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16",
        64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    /// the number pad types the same as the main row: its keys get their own name
    static let keypad: [UInt16: String] = [
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
        65: ",", 67: "*", 69: "+", 75: "/", 78: "-", 81: "=", 71: "⌧",
    ]
    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    /// F1-F12: media keys on Apple keyboards unless fn is held or they are standard function keys
    static let topRow: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    /// keys for writing and moving around in text
    static let editingKeys: Set<UInt16> = [36, 48, 51, 53, 76, 114, 115, 116, 117, 119, 121, 123, 124, 125, 126]
    /// volume and mute (most media keys never arrive as keys at all)
    static let mediaKeys: Set<UInt16> = [72, 73, 74]

    /// what a key types on the current keyboard layout with these Carbon modifiers, and whether it is
    /// a dead key (an accent that waits for the next letter; then the accent itself); nil: nothing
    static func typedInfo(_ keyCode: UInt16, mods: UInt32) -> (text: String, dead: Bool)? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        func translate(_ code: UInt16, _ state: UInt32, _ dead: inout UInt32) -> String? {
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = data.withUnsafeBytes { buffer -> OSStatus in
                guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
                return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), state, UInt32(LMGetKbdType()),
                                      0, &dead, chars.count, &length, &chars)
            }
            guard status == noErr else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
        var dead: UInt32 = 0
        guard let first = translate(keyCode, (mods >> 8) & 0xFF, &dead) else { return nil }
        if first.isEmpty && dead != 0 {
            let accent = translate(49, 0, &dead) ?? ""            // the accent on its own (space after it)
            return accent.isEmpty ? nil : (accent.trimmingCharacters(in: .whitespaces).isEmpty ? accent : accent.trimmingCharacters(in: .whitespaces), true)
        }
        let printable = first.unicodeScalars.contains { !CharacterSet.controlCharacters.contains($0) }
        return printable && !first.isEmpty ? (first, false) : nil
    }

    static func typed(_ keyCode: UInt16, mods: UInt32) -> String? { typedInfo(keyCode, mods: mods)?.text }

    /// how the key reads on its cap: "W", "2", "F5", "←"
    static func keyName(_ keyCode: UInt16) -> String? {
        if let name = specialNames[keyCode] { return name == "Space" ? L("Leertaste") : name }
        if let pad = keypad[keyCode] { return L("Ziffernblock %@", pad) }
        guard let c = typed(keyCode, mods: 0), !c.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let upper = c.uppercased()
        return upper.count == c.count ? upper : c          // ß stays ß, not SS
    }

    /// the character menus match a ⌘ shortcut by (the ⌘ layer of the layout: ⌘Z is undo on a German
    /// keyboard too, although the key sits elsewhere)
    static func menuToken(_ keyCode: UInt16) -> String? {
        if specialNames[keyCode] != nil { return nil }
        return (typed(keyCode, mods: cmd) ?? typed(keyCode, mods: 0))?.lowercased()
    }

    static func glyphs(_ mods: UInt32) -> String {
        (mods & control != 0 ? "⌃" : "") + (mods & option != 0 ? "⌥" : "") + (mods & shift != 0 ? "⇧" : "") + (mods & cmd != 0 ? "⌘" : "")
    }

    static func label(_ code: UInt16, _ mods: UInt32) -> String { glyphs(mods) + (keyName(code) ?? "?") }

    // MARK: what macOS holds

    struct SystemEntry { let code: UInt16; let mods: UInt32; let enabled: Bool }

    /// macOS's own shortcuts (System Settings, Keyboard, Keyboard Shortcuts) with the user's changes,
    /// switched on or off; read once per recording (the list has some 200 entries)
    static func systemShortcuts() -> [SystemEntry] {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let items = list?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let code = (item[kHISymbolicHotKeyCode as String] as? NSNumber)?.intValue,
                  let raw = (item[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value,
                  code >= 0, code < 0xFFFF else { return nil }
            let key = UInt16(code)
            // the fn bit comes by itself with F-keys, arrows and the like; on other keys it is a 🌐
            // shortcut of its own (🌐Q, 🌐F), not the same keys without 🌐
            if raw & fnFlag != 0 && !functionKeys.contains(key) && !editingKeys.contains(key) { return nil }
            let mods = raw & (cmd | shift | option | control)
            if key == 111 && (mods == 0 || mods == shift) { return nil }   // F12 and ⇧F12: Dashboard, gone
            // fn-flagged arrows and the like without ⌃ or ⌘ are the plain keys (text editing), not
            // system shortcuts (their reason comes from the editing rule)
            if raw & fnFlag != 0 && editingKeys.contains(key) && mods & (control | cmd) == 0 { return nil }
            return SystemEntry(code: key, mods: mods, enabled: (item[kHISymbolicHotKeyEnabled as String] as? Bool) == true)
        }
    }

    enum Kind { case always, system, refuse, terminalRefuse, terminal, warn }

    struct Named {
        let code: UInt16?
        let token: String?
        let mods: UInt32
        let de: String
        let en: String
        let kind: Kind
        let scope: String
        var text: String { Loc.shared.english ? en : de }
    }

    /// what the keys do in macOS, in nearly every app, in text fields, in the Terminal, in common apps
    /// (the research's named table of 10.10.; system entries by key code, the others by character)
    static let named: [Named] = {
        let c = cmd, s = shift, o = option, k = control
        func n(code: UInt16? = nil, token: String? = nil, _ m: UInt32, _ de: String, _ en: String, _ kind: Kind, _ scope: String) -> Named {
            Named(code: code, token: token, mods: m, de: de, en: en, kind: kind, scope: scope)
        }
        return [
            n(code: 49, c, "öffnet die Spotlight-Suche", "opens Spotlight search", .system, "system"),   // ⌘Leertaste
            n(code: 49, o | c, "öffnet das Finder-Suchfenster", "opens the Finder search window", .system, "system"),   // ⌥⌘Leertaste
            n(code: 49, k | c, "öffnet Emoji & Symbole", "opens Emoji & Symbols", .system, "system"),   // ⌃⌘Leertaste
            n(code: 49, k, "wählt die vorherige Eingabequelle", "selects the previous input source", .system, "system"),   // ⌃Leertaste
            n(code: 49, k | o, "wählt die nächste Eingabequelle", "selects the next input source", .system, "system"),   // ⌃⌥Leertaste
            n(code: 48, c, "wechselt zwischen Apps", "switches apps", .always, "system"),   // ⌘⇥
            n(code: 48, s | c, "wechselt rückwärts zwischen Apps", "switches apps backwards", .always, "system"),   // ⇧⌘⇥
            n(code: 50, c, "wechselt zum nächsten Fenster der App", "moves focus to the app's next window", .system, "system"),   // ⌘< (US ⌘`)
            n(code: 50, s | c, "wechselt zum vorigen Fenster der App", "moves focus to the app's previous window", .system, "system"),   // ⇧⌘< (US ⇧⌘`)
            n(code: 50, o | c, "setzt den Fokus auf die Schublade des Fensters", "moves focus to the window drawer", .system, "system"),   // ⌥⌘< (US ⌥⌘`)
            n(code: 20, s | c, "sichert ein Bildschirmfoto als Datei", "saves a picture of the screen as a file", .system, "system"),   // ⇧⌘3
            n(code: 20, k | s | c, "kopiert ein Bildschirmfoto in die Zwischenablage", "copies a picture of the screen to the clipboard", .system, "system"),   // ⌃⇧⌘3
            n(code: 21, s | c, "sichert ein Bild des ausgewählten Bereichs", "saves a picture of the selected area", .system, "system"),   // ⇧⌘4
            n(code: 21, k | s | c, "kopiert ein Bild des ausgewählten Bereichs", "copies a picture of the selected area", .system, "system"),   // ⌃⇧⌘4
            n(code: 23, s | c, "öffnet die Optionen für Bildschirmfotos und Bildschirmaufnahmen", "opens screenshot and recording options", .system, "system"),   // ⇧⌘5
            n(code: 22, s | c, "sichert ein Bild der Touch Bar", "saves a picture of the Touch Bar", .system, "system"),   // ⇧⌘6
            n(code: 22, k | s | c, "kopiert ein Bild der Touch Bar", "copies a picture of the Touch Bar", .system, "system"),   // ⌃⇧⌘6
            n(code: 53, o | c, "öffnet „Sofort beenden“", "opens Force Quit", .always, "system"),   // ⌥⌘Esc
            n(code: 53, o | s | c, "beendet die vorderste App sofort", "force quits the frontmost app", .always, "system"),   // ⌥⇧⌘Esc
            n(code: 53, c, "öffnet die Spielüberlagerung (macOS 26)", "opens the Game Overlay (macOS 26)", .system, "system"),   // ⌘Esc
            n(code: 53, o, "liest die Auswahl vor", "speaks the selection", .system, "system"),   // ⌥Esc
            n(code: 126, k, "öffnet Mission Control", "opens Mission Control", .system, "system"),   // ⌃↑
            n(code: 125, k, "zeigt alle Fenster der App", "shows the app's windows", .system, "system"),   // ⌃↓
            n(code: 123, k, "wechselt einen Space nach links", "moves left a space", .system, "system"),   // ⌃←
            n(code: 124, k, "wechselt einen Space nach rechts", "moves right a space", .system, "system"),   // ⌃→
            n(code: 18, k, "wechselt zu Schreibtisch 1", "switches to Desktop 1", .system, "system"),   // ⌃1 (⌃2 bis ⌃0 entsprechend)
            n(code: 19, k, "wechselt zu Schreibtisch 2", "switches to Desktop 2", .system, "system"),   // ⌃1 (⌃2 bis ⌃0 entsprechend)
            n(code: 20, k, "wechselt zu Schreibtisch 3", "switches to Desktop 3", .system, "system"),   // ⌃1 (⌃2 bis ⌃0 entsprechend)
            n(code: 21, k, "wechselt zu Schreibtisch 4", "switches to Desktop 4", .system, "system"),   // ⌃1 (⌃2 bis ⌃0 entsprechend)
            n(code: 23, k, "wechselt zu Schreibtisch 5", "switches to Desktop 5", .system, "system"),   // ⌃1 (⌃2 bis ⌃0 entsprechend)
            n(code: 22, k, "wechselt zu Schreibtisch 6", "switches to Desktop 6", .system, "system"),   // ⌃1 (⌃2 bis ⌃0 entsprechend)
            n(code: 26, k, "wechselt zu Schreibtisch 7", "switches to Desktop 7", .system, "system"),   // ⌃1 (⌃2 bis ⌃0 entsprechend)
            n(code: 28, k, "wechselt zu Schreibtisch 8", "switches to Desktop 8", .system, "system"),   // ⌃1 (⌃2 bis ⌃0 entsprechend)
            n(code: 25, k, "wechselt zu Schreibtisch 9", "switches to Desktop 9", .system, "system"),   // ⌃1 (⌃2 bis ⌃0 entsprechend)
            n(code: 29, k, "wechselt zu Schreibtisch 10", "switches to Desktop 10", .system, "system"),   // ⌃1 (⌃2 bis ⌃0 entsprechend)
            n(code: 103, 0, "zeigt den Schreibtisch", "shows the desktop", .system, "system"),   // F11
            n(code: 107, 0, "verringert die Bildschirmhelligkeit", "decreases display brightness", .system, "system"),   // F14
            n(code: 113, 0, "erhöht die Bildschirmhelligkeit", "increases display brightness", .system, "system"),   // F15
            n(code: 122, k, "schaltet die Tastatursteuerung ein oder aus", "turns keyboard access on or off", .system, "system"),   // ⌃F1
            n(code: 120, k, "setzt den Fokus auf die Menüleiste", "moves focus to the menu bar", .system, "system"),   // ⌃F2
            n(code: 99, k, "setzt den Fokus auf das Dock", "moves focus to the Dock", .system, "system"),   // ⌃F3
            n(code: 118, k, "setzt den Fokus auf das aktive oder nächste Fenster", "moves focus to the active or next window", .system, "system"),   // ⌃F4
            n(code: 96, k, "setzt den Fokus auf die Symbolleiste des Fensters", "moves focus to the window toolbar", .system, "system"),   // ⌃F5
            n(code: 97, k, "setzt den Fokus auf das schwebende Fenster", "moves focus to the floating window", .system, "system"),   // ⌃F6
            n(code: 98, k, "ändert, wie der Tabulator den Fokus bewegt", "changes the way Tab moves focus", .system, "system"),   // ⌃F7
            n(code: 100, k, "setzt den Fokus auf die Statusmenüs", "moves focus to the status menus", .system, "system"),   // ⌃F8
            n(code: 118, k | s, "setzt vermutlich den Fokus auf das vorige Fenster", "probably moves focus to the previous window", .system, "system"),   // ⌃⇧F4
            n(code: 96, c, "schaltet VoiceOver ein oder aus", "turns VoiceOver on or off", .system, "system"),   // ⌘F5
            n(code: 96, o | c, "öffnet die Steuerung für Bedienungshilfen", "shows the Accessibility controls", .system, "system"),   // ⌥⌘F5
            n(code: 122, c, "spiegelt vermutlich die Bildschirme", "probably mirrors the displays", .system, "system"),   // ⌘F1
            n(code: 101, k, "", "", .system, "system"),   // ⌃F9
            n(code: 2, o | c, "blendet das Dock ein oder aus", "turns Dock hiding on or off", .system, "system"),   // ⌥⌘D
            n(code: 2, k | c, "schlägt das Wort im Lexikon nach", "looks up the word in the Dictionary", .system, "system"),   // ⌃⌘D
            n(code: 36, k, "öffnet das Kontextmenü", "shows the contextual menu", .system, "system"),   // ⌃↩
            n(code: 46, c, "legt das Fenster im Dock ab", "minimizes the window", .system, "system"),   // ⌘M
            n(code: 46, o | c, "legt alle Fenster der App im Dock ab", "minimizes all of the app's windows", .system, "system"),   // ⌥⌘M
            n(code: 12, k | c, "sperrt den Bildschirm", "locks the screen", .always, "system"),   // ⌃⌘Q
            n(code: 12, s | c, "meldet dich ab", "logs you out", .always, "system"),   // ⇧⌘Q
            n(code: 12, o | s | c, "meldet dich ohne Rückfrage ab", "logs you out without asking", .always, "system"),   // ⌥⇧⌘Q
            n(code: 47, k | o | s | c, "startet eine Systemdiagnose (sysdiagnose)", "starts a system diagnosis (sysdiagnose)", .always, "system"),   // ⌃⌥⇧⌘.
            n(code: 12, k | o | s | c, "", "", .system, "system"),   // ⌃⌥⇧⌘Q
            n(code: 1, k | c, "", "", .system, "system"),   // ⌃⌘S
            n(code: 3, s | c, "sucht vermutlich mit Spotlight", "probably searches with Spotlight", .system, "system"),   // ⇧⌘F
            n(code: 28, o | c, "schaltet den Zoom ein oder aus", "turns Zoom on or off", .system, "system"),   // ⌥⌘8
            n(code: 24, o | c, "vergrößert mit dem Zoom", "zooms in", .system, "system"),   // ⌥⌘= (DE ⌥⌘´)
            n(code: 27, o | c, "verkleinert mit dem Zoom", "zooms out", .system, "system"),   // ⌥⌘- (DE ⌥⌘ß)
            n(code: 28, k | o | c, "kehrt die Farben um", "inverts colors", .system, "system"),   // ⌃⌥⌘8
            n(code: 47, k | o | c, "erhöht den Kontrast", "increases contrast", .system, "system"),   // ⌃⌥⌘.
            n(code: 43, k | o | c, "verringert den Kontrast", "decreases contrast", .system, "system"),   // ⌃⌥⌘,
            n(code: 49, k | s, "blendet die Trackpad-Handschrift ein oder aus", "shows or hides Trackpad Handwriting", .system, "system"),   // ⌃⇧Leertaste
            n(code: 49, s | c, "fragt ab macOS 27 Siri zum aktiven Fenster", "asks Siri about the active window from macOS 27 on", .system, "system"),   // ⇧⌘Leertaste
            n(token: "q", c, "beendet die App", "quits the app", .refuse, "all-apps"),   // ⌘Q
            n(token: "w", c, "schließt das Fenster", "closes the window", .refuse, "all-apps"),   // ⌘W
            n(token: "h", c, "blendet die App aus", "hides the app", .refuse, "all-apps"),   // ⌘H
            n(token: ",", c, "öffnet die Einstellungen", "opens the settings", .refuse, "all-apps"),   // ⌘,
            n(token: "n", c, "öffnet ein neues Dokument oder Fenster", "opens a new document or window", .refuse, "all-apps"),   // ⌘N
            n(token: "o", c, "öffnet eine Datei", "opens a file", .refuse, "all-apps"),   // ⌘O
            n(token: "s", c, "sichert", "saves", .refuse, "all-apps"),   // ⌘S
            n(token: "p", c, "druckt", "prints", .refuse, "all-apps"),   // ⌘P
            n(token: "z", c, "widerruft", "undoes", .refuse, "all-apps"),   // ⌘Z
            n(token: "z", s | c, "wiederholt den letzten Schritt", "redoes", .refuse, "all-apps"),   // ⇧⌘Z
            n(token: "x", c, "schneidet aus", "cuts", .refuse, "all-apps"),   // ⌘X
            n(token: "c", c, "kopiert", "copies", .refuse, "all-apps"),   // ⌘C
            n(token: "v", c, "setzt ein", "pastes", .refuse, "all-apps"),   // ⌘V
            n(token: "a", c, "wählt alles aus", "selects all", .refuse, "all-apps"),   // ⌘A
            n(token: "f", c, "sucht", "finds", .refuse, "all-apps"),   // ⌘F
            n(token: "g", c, "sucht weiter", "finds next", .refuse, "all-apps"),   // ⌘G
            n(token: "g", s | c, "sucht rückwärts (im Finder: Gehe zu Ordner)", "finds previous (Finder: Go to Folder)", .refuse, "all-apps"),   // ⇧⌘G
            n(token: "t", c, "öffnet einen neuen Tab", "opens a new tab", .refuse, "all-apps"),   // ⌘T
            n(token: ".", c, "bricht ab", "cancels", .refuse, "all-apps"),   // ⌘.
            n(token: "1", c, "wählt Tab 1 oder Darstellung 1", "selects tab 1 or view 1", .refuse, "all-apps"),   // ⌘1 (⌘2 bis ⌘9 entsprechend)
            n(token: "2", c, "wählt Tab 2 oder Darstellung 2", "selects tab 2 or view 2", .refuse, "all-apps"),   // ⌘1 (⌘2 bis ⌘9 entsprechend)
            n(token: "3", c, "wählt Tab 3 oder Darstellung 3", "selects tab 3 or view 3", .refuse, "all-apps"),   // ⌘1 (⌘2 bis ⌘9 entsprechend)
            n(token: "4", c, "wählt Tab 4 oder Darstellung 4", "selects tab 4 or view 4", .refuse, "all-apps"),   // ⌘1 (⌘2 bis ⌘9 entsprechend)
            n(token: "5", c, "wählt Tab 5 oder Darstellung 5", "selects tab 5 or view 5", .refuse, "all-apps"),   // ⌘1 (⌘2 bis ⌘9 entsprechend)
            n(token: "6", c, "wählt Tab 6 oder Darstellung 6", "selects tab 6 or view 6", .refuse, "all-apps"),   // ⌘1 (⌘2 bis ⌘9 entsprechend)
            n(token: "7", c, "wählt Tab 7 oder Darstellung 7", "selects tab 7 or view 7", .refuse, "all-apps"),   // ⌘1 (⌘2 bis ⌘9 entsprechend)
            n(token: "8", c, "wählt Tab 8 oder Darstellung 8", "selects tab 8 or view 8", .refuse, "all-apps"),   // ⌘1 (⌘2 bis ⌘9 entsprechend)
            n(token: "9", c, "wählt Tab 9 oder Darstellung 9", "selects tab 9 or view 9", .refuse, "all-apps"),   // ⌘1 (⌘2 bis ⌘9 entsprechend)
            n(token: "h", o | c, "blendet die anderen Apps aus", "hides the other apps", .refuse, "all-apps"),   // ⌥⌘H
            n(token: "w", o | c, "schließt alle Fenster der App", "closes all of the app's windows", .refuse, "all-apps"),   // ⌥⌘W
            n(token: "s", s | c, "sichert unter neuem Namen oder dupliziert", "saves as or duplicates", .refuse, "all-apps"),   // ⇧⌘S
            n(token: "v", o | s | c, "setzt ein und passt den Stil an", "pastes and matches style", .refuse, "all-apps"),   // ⌥⇧⌘V
            n(token: "f", k | c, "schaltet auf Vollbild", "enters full screen", .refuse, "all-apps"),   // ⌃⌘F
            n(token: "/", s | c, "öffnet die Hilfe", "opens Help", .refuse, "all-apps"),   // ⇧⌘? on US
            n(token: "ß", s | c, "öffnet die Hilfe", "opens Help", .refuse, "all-apps"),   // ⇧⌘? on German
            n(code: 48, k, "wechselt zum nächsten Tab", "moves to the next tab", .refuse, "all-apps"),   // ⌃⇥
            n(code: 48, k | s, "wechselt zum vorigen Tab", "moves to the previous tab", .refuse, "all-apps"),   // ⌃⇧⇥
            n(token: "a", k, "springt an den Zeilenanfang", "moves to the start of the line", .refuse, "text"),   // ⌃A
            n(token: "e", k, "springt ans Zeilenende", "moves to the end of the line", .refuse, "text"),   // ⌃E
            n(token: "b", k, "geht ein Zeichen zurück", "moves one character back", .refuse, "text"),   // ⌃B
            n(token: "f", k, "geht ein Zeichen vor", "moves one character forward", .refuse, "text"),   // ⌃F
            n(token: "n", k, "geht eine Zeile runter", "moves one line down", .refuse, "text"),   // ⌃N
            n(token: "p", k, "geht eine Zeile hoch", "moves one line up", .refuse, "text"),   // ⌃P
            n(token: "d", k, "löscht das Zeichen rechts", "deletes the character to the right", .refuse, "text"),   // ⌃D
            n(token: "h", k, "löscht das Zeichen links", "deletes the character to the left", .refuse, "text"),   // ⌃H
            n(token: "k", k, "löscht bis zum Zeilenende", "deletes to the end of the line", .refuse, "text"),   // ⌃K
            n(token: "y", k, "setzt das zuletzt mit ⌃K Gelöschte ein", "pastes what ⌃K deleted last", .refuse, "text"),   // ⌃Y
            n(token: "t", k, "vertauscht zwei Zeichen", "transposes two characters", .refuse, "text"),   // ⌃T
            n(token: "v", k, "blättert eine Seite weiter", "scrolls one page down", .refuse, "text"),   // ⌃V
            n(token: "o", k, "fügt hinter dem Cursor eine Zeile ein", "inserts a line after the cursor", .refuse, "text"),   // ⌃O
            n(token: "l", k, "zentriert die Ansicht auf den Cursor", "centers the view on the cursor", .refuse, "text"),   // ⌃L
            n(token: "a", k | s, "markiert bis zum Zeilenanfang", "selects to the start of the line", .refuse, "text"),   // ⌃⇧A
            n(token: "e", k | s, "markiert bis zum Zeilenende", "selects to the end of the line", .refuse, "text"),   // ⌃⇧E
            n(token: "b", k | s, "markiert ein Zeichen nach links", "extends the selection one character back", .refuse, "text"),   // ⌃⇧B
            n(token: "f", k | s, "markiert ein Zeichen nach rechts", "extends the selection one character forward", .refuse, "text"),   // ⌃⇧F
            n(token: "n", k | s, "markiert eine Zeile nach unten", "extends the selection one line down", .refuse, "text"),   // ⌃⇧N
            n(token: "p", k | s, "markiert eine Zeile nach oben", "extends the selection one line up", .refuse, "text"),   // ⌃⇧P
            n(token: "v", k | s, "markiert eine Seite nach unten", "extends the selection one page down", .refuse, "text"),   // ⌃⇧V
            n(token: "b", k | o, "springt ein Wort zurück", "moves one word back", .refuse, "text"),   // ⌃⌥B
            n(token: "f", k | o, "springt ein Wort vor", "moves one word forward", .refuse, "text"),   // ⌃⌥F
            n(code: 123, o, "springt ein Wort zurück", "moves one word back", .refuse, "text"),   // ⌥←
            n(code: 124, o, "springt ein Wort vor", "moves one word forward", .refuse, "text"),   // ⌥→
            n(code: 51, o, "löscht das Wort links", "deletes the word to the left", .refuse, "text"),   // ⌥⌫
            n(code: 123, c, "springt an den Zeilenanfang", "moves to the start of the line", .refuse, "text"),   // ⌘←
            n(code: 51, c, "löscht bis zum Zeilenanfang (im Finder: legt in den Papierkorb)", "deletes to the start of the line (Finder: moves to Trash)", .refuse, "text"),   // ⌘⌫
            n(code: 36, o, "fügt im Feld einen Zeilenumbruch ein", "inserts a line break in the field", .refuse, "text"),   // ⌥↩
            n(code: 49, o, "tippt ein geschütztes Leerzeichen", "types a no-break space", .warn, "text"),   // ⌥Leertaste
            n(code: 49, o | s, "tippt ein geschütztes Leerzeichen", "types a no-break space", .warn, "text"),   // ⌥⇧Leertaste
            n(token: "c", k, "bricht den laufenden Befehl ab", "interrupts the running command", .terminalRefuse, "terminal"),   // ⌃C
            n(token: "z", k, "hält den laufenden Befehl an", "suspends the running command", .terminal, "terminal"),   // ⌃Z
            n(token: "w", k, "löscht das Wort vor dem Cursor", "deletes the word before the cursor", .terminal, "terminal"),   // ⌃W
            n(token: "u", k, "löscht die Zeile", "deletes the line", .terminal, "terminal"),   // ⌃U
            n(token: "r", k, "sucht rückwärts im Verlauf", "searches the history backwards", .terminal, "terminal"),   // ⌃R
            n(token: "s", k, "hält die Ausgabe an oder sucht vorwärts im Verlauf", "stops output or searches the history forward", .terminal, "terminal"),   // ⌃S
            n(token: "q", k, "setzt die Ausgabe fort (zsh: stellt die Zeile zurück)", "resumes output (zsh: pushes the line aside)", .terminal, "terminal"),   // ⌃Q
            n(token: "x", k, "beginnt Tastenfolgen der Shell (nano: beendet)", "starts shell key sequences (nano: exits)", .terminal, "terminal"),   // ⌃X
            n(token: "g", k, "bricht die Eingabe ab", "aborts the input", .terminal, "terminal"),   // ⌃G
            n(token: "\\", k, "beendet den Befehl hart (SIGQUIT)", "quits the command hard (SIGQUIT)", .terminal, "terminal"),   // ⌃ mit Backslash
            n(token: "a", s | c, "öffnet im Finder die Programme", "opens Applications in the Finder", .warn, "common-apps"),   // ⇧⌘A
            n(token: "d", s | c, "öffnet im Finder den Schreibtisch", "opens the Desktop in the Finder", .warn, "common-apps"),   // ⇧⌘D
            n(token: "h", s | c, "öffnet im Finder den Benutzerordner", "opens the home folder in the Finder", .warn, "common-apps"),   // ⇧⌘H
            n(token: "o", s | c, "öffnet im Finder die Dokumente", "opens Documents in the Finder", .warn, "common-apps"),   // ⇧⌘O
            n(token: "r", s | c, "öffnet im Finder AirDrop und in Safari den Reader", "opens AirDrop in the Finder and Reader in Safari", .warn, "common-apps"),   // ⇧⌘R
            n(token: ".", s | c, "zeigt im Finder versteckte Dateien", "shows hidden files in the Finder", .warn, "common-apps"),   // ⇧⌘.
            n(token: "l", o | c, "öffnet im Finder und in Safari die Downloads", "opens Downloads in the Finder and Safari", .warn, "common-apps"),   // ⌥⌘L
            n(token: "l", s | c, "sucht mit dem Safari-Dienst „Mit Google suchen“", "runs Safari's 'Search With Google' service", .warn, "common-apps"),   // ⇧⌘L
            n(token: "y", s | c, "erstellt mit dem Dienst einen Notizzettel", "makes a sticky note with the service", .warn, "common-apps"),   // ⇧⌘Y
            n(token: "m", s | c, "öffnet mit dem Terminal-Dienst die man-Seite", "opens the man page with the Terminal service", .warn, "common-apps"),   // ⇧⌘M
            n(token: "b", s | c, "blendet im Browser die Lesezeichenleiste ein oder aus", "shows or hides the browser's bookmarks bar", .warn, "common-apps"),   // ⇧⌘B
            n(token: "n", s | c, "erstellt im Finder einen neuen Ordner und öffnet im Browser ein privates Fenster", "makes a new folder in the Finder and opens a private browser window", .warn, "common-apps"),   // ⇧⌘N
            n(token: "t", s | c, "öffnet im Browser den zuletzt geschlossenen Tab wieder", "reopens the last closed browser tab", .warn, "common-apps"),   // ⇧⌘T
            n(token: "w", s | c, "schließt in Browsern und vielen Apps das ganze Fenster", "closes the whole window in browsers and many apps", .warn, "common-apps"),   // ⇧⌘W
            n(token: "v", s | c, "setzt in vielen Apps ohne Formatierung ein", "pastes without formatting in many apps", .warn, "common-apps"),   // ⇧⌘V
            n(token: "p", s | c, "öffnet „Papierformat“", "opens Page Setup", .warn, "common-apps"),   // ⇧⌘P
            n(token: "i", o | c, "öffnet im Browser die Entwicklerwerkzeuge", "opens the browser's developer tools", .warn, "common-apps"),   // ⌥⌘I
            n(token: "j", o | c, "öffnet im Browser die Konsole", "opens the browser's console", .warn, "common-apps"),   // ⌥⌘J
            n(token: "c", o | c, "kopiert in Textprogrammen den Stil", "copies the style in text apps", .warn, "common-apps"),   // ⌥⌘C
            n(token: "v", o | c, "setzt in Textprogrammen den Stil ein und bewegt im Finder kopierte Dateien", "pastes the style in text apps and moves copied files in the Finder", .warn, "common-apps"),   // ⌥⌘V
            n(token: "s", o | c, "blendet im Finder die Seitenleiste ein oder aus", "shows or hides the Finder sidebar", .warn, "common-apps"),   // ⌥⌘S
            n(token: "t", o | c, "blendet die Symbolleiste ein oder aus", "shows or hides the toolbar", .warn, "common-apps"),   // ⌥⌘T
            n(token: "p", o | c, "blendet im Finder die Pfadleiste ein oder aus", "shows or hides the Finder path bar", .warn, "common-apps"),   // ⌥⌘P
            n(token: "a", k | c, "erzeugt im Finder ein Alias", "makes an alias in the Finder", .warn, "common-apps"),   // ⌃⌘A
            n(token: "t", k | c, "fügt im Finder das Objekt zur Seitenleiste hinzu", "adds the item to the Finder sidebar", .warn, "common-apps"),   // ⌃⌘T
            n(code: 51, s | c, "leert im Finder den Papierkorb", "empties the Trash in the Finder", .warn, "common-apps"),   // ⇧⌘⌫
            n(token: "]", s | c, "wechselt in Browsern und vielen Apps zum nächsten Tab", "moves to the next tab in browsers and many apps", .warn, "common-apps"),
            n(token: "[", s | c, "wechselt in Browsern und vielen Apps zum vorigen Tab", "moves to the previous tab in browsers and many apps", .warn, "common-apps"),
            n(token: "\\", s | c, "zeigt in Safari alle Tabs", "shows all tabs in Safari", .warn, "common-apps"),
        ]
    }()

    /// ⌘ with a single key: what it does in nearly every app (for keys the table does not name)
    static let commandOnly: [String: (de: String, en: String)] = [
        "b": ("macht Text fett", "makes text bold"), "i": ("macht Text kursiv", "makes text italic"),
        "u": ("unterstreicht Text", "underlines text"), "k": ("fügt einen Link ein", "inserts a link"),
        "l": ("springt in die Adressleiste", "jumps to the address bar"), "r": ("lädt neu", "reloads"),
        "e": ("übernimmt die Auswahl für die Suche", "uses the selection for find"),
        "d": ("dupliziert oder setzt ein Lesezeichen", "duplicates or bookmarks"),
        "j": ("springt zur Auswahl", "jumps to the selection"), "y": ("zeigt den Verlauf", "shows the history"),
        "0": ("setzt die Größe zurück", "resets the zoom"), "+": ("vergrößert", "zooms in"),
        "=": ("vergrößert", "zooms in"), "-": ("verkleinert", "zooms out"), "ß": ("verkleinert", "zooms out"),
    ]

    private static func hit(_ code: UInt16, _ mods: UInt32, _ kinds: Set<String>? = nil) -> Named? {
        let token = menuToken(code)
        let base = mods & ~shift
        return named.first { n in
            let keyMatch = n.code.map { $0 == code } ?? (token != nil && n.token == token)
            let modsMatch = n.mods == mods || (n.kind == .terminal && n.mods == control && base == control)
            return keyMatch && modsMatch && (kinds == nil || kinds!.contains(n.scope))
        }
    }

    // MARK: verdicts

    /// a key with modifiers (or an F-key alone) for `target`; `others` are the other modes' shortcuts;
    /// `system` the list read when the recording started
    static func judgeKey(code: UInt16, mods: UInt32, target: String, others: [String: Shortcut],
                         system: [SystemEntry]) -> Verdict {
        let keys = label(code, mods)
        var note: String?
        func refuse(_ s: String) -> Verdict { .refuse(s) }

        if code == 53 && mods == 0 { return refuse(L("Esc bricht die Aufnahme ab")) }
        // [2] volume and mute
        if mediaKeys.contains(code) {
            return refuse(L("Lautstärke-, Medien- und Helligkeitstasten behält macOS für sich. Nimm eine F-Taste oder eine Kombination mit ⌃ oder ⌘."))
        }
        // [4] VoiceBud's own shortcuts
        let combo = KeyCombo(key: UInt32(code), mods: mods, label: keys)
        if let why = clash(.key(combo), target: target, others: others) { return refuse(why) }
        // [5] what always belongs to macOS (Apple menu, sysdiagnose, the app switcher)
        if let n = named.first(where: { $0.kind == .always && $0.code == code && $0.mods == mods && !$0.de.isEmpty }) {
            return refuse(L("%@ %@, das gehört immer macOS. Nimm eine andere Kombination.", keys, n.text))
        }
        // [6] switched on in macOS: refused; [7] a known one that is switched off here: a note
        let entries = system.filter { $0.code == code && $0.mods == mods }
        let named6 = named.first { $0.kind == .system && $0.code == code && $0.mods == mods && !$0.de.isEmpty }
        if entries.contains(where: \.enabled) {
            if let named6 {
                return refuse(L("%@ %@, das ist ein Kurzbefehl von macOS (Systemeinstellungen > Tastatur > Tastaturkurzbefehle). Nimm eine andere Kombination.", keys, named6.text))
            }
            return refuse(L("%@ belegt macOS selbst (Systemeinstellungen > Tastatur > Tastaturkurzbefehle). Nimm eine andere Kombination.", keys))
        }
        if let named6, !entries.isEmpty {
            note = L("Hinweis: %@ %@, sobald du diesen Kurzbefehl in macOS einschaltest. Bei dir ist er aus. Schaltest du ihn später ein, gewinnt macOS.", keys, named6.text)
        }
        // [8] ⌘ with one key: the apps' menus (with an arrow, ⌫ or ↩ the text rules below say more)
        if mods == cmd && !editingKeys.contains(code) {
            if let n = hit(code, mods, ["all-apps"]) {
                return refuse(L("%@ %@, und das in fast jeder App. Als Kurzbefehl von VoiceBud ginge das überall verloren. Nimm ⌃, ⌥ oder ⇧ dazu.", keys, n.text))
            }
            if let token = menuToken(code), let what = commandOnly[token] {
                return refuse(L("%@ %@, und das in fast jeder App. Als Kurzbefehl von VoiceBud ginge das überall verloren. Nimm ⌃, ⌥ oder ⇧ dazu.",
                                keys, Loc.shared.english ? what.en : what.de))
            }
            if !functionKeys.contains(code) {
                return refuse(L("⌘ mit nur einer Taste gehört den Menübefehlen der Apps. Nimm ⌃, ⌥ oder ⇧ dazu."))
            }
        }
        // [9] [10] menu shortcuts nearly every app has, the text system's keys
        if let n = hit(code, mods, ["all-apps", "text"]), n.kind == .refuse {
            if n.scope == "text" {
                return refuse(L("%@ %@, und das in jedem Textfeld von macOS. Als Kurzbefehl ginge das überall verloren. Nimm eine andere Kombination.", keys, n.text))
            }
            return refuse(L("%@ %@, und das in fast jeder App. Als Kurzbefehl von VoiceBud ginge das überall verloren. Nimm eine andere Kombination.", keys, n.text))
        }
        // [11] [12] editing and navigation keys: alone, with ⇧, or with ⌥ or ⌘ (and ⇧) they move and
        // select in text; other sets only some apps use
        if editingKeys.contains(code) {
            let navigation = mods & control == 0 && [mods & option, mods & cmd].filter { $0 != 0 }.count <= 1
            if navigation {
                return refuse(L("%@ braucht jede App zum Schreiben und Bewegen im Text. Nimm einen Buchstaben, eine Zahl oder eine F-Taste.", keys))
            }
            note = note ?? L("Hinweis: %@ nutzen manche Apps selbst, etwa Fenster-Tools mit ⌃⌥ und Pfeiltasten oder Chat-Apps zum Abschicken. Dort geht es dann nicht mehr.", keys)
        }
        // [13] no modifier or ⇧ only on a key that types
        if mods & (cmd | control | option) == 0, let ch = typed(code, mods: mods) {
            if code == 49 { return refuse(L("Die Leertaste braucht man zum Schreiben. Nimm ⌃ oder ⌘ dazu.")) }
            return refuse(L("%@ tippt „%@“. Als Kurzbefehl könntest du das in keiner App mehr schreiben. Nimm ⌃, ⌥ oder ⌘ dazu.", keys, ch))
        }
        if mods & (cmd | control | option) == 0 && !functionKeys.contains(code) && !editingKeys.contains(code) {
            return refuse(L("%@ geht als Kurzbefehl nicht. Nimm ⌃, ⌥ oder ⌘ dazu.", keys))
        }
        // [14] [15] ⌥ or ⌥⇧ without ⌃ and ⌘ on a key that types: needed characters refused, rare ones noted
        if mods & (cmd | control) == 0, mods & option != 0, let info = typedInfo(code, mods: mods) {
            if info.dead && !deadElsewhere(info.text, besides: code) {
                return refuse(L("%@ setzt auf deiner Tastatur den Akzent „%@“ (für Buchstaben wie ñ oder é). Als Kurzbefehl ginge der überall verloren. Nimm ⌃ oder ⌘ dazu.", keys, info.text))
            }
            if !info.dead && needed(info.text, besides: code) {
                return refuse(L("%@ tippt auf deiner Tastatur „%@“. Als Kurzbefehl könntest du „%@“ in keiner App mehr schreiben. Nimm ⌃ oder ⌘ dazu.", keys, info.text, info.text))
            }
            if let n = hit(code, mods, ["text"]), n.kind == .warn {
                note = L("Hinweis: %@ %@, das geht dann nicht mehr.", keys, n.text)
            } else if info.text.trimmingCharacters(in: .whitespaces).isEmpty {
                note = L("Hinweis: %@ tippt auf deiner Tastatur ein Leerzeichen, das geht dann in keiner App mehr.", keys)
            } else {
                note = L("Hinweis: %@ tippt auf deiner Tastatur „%@“, das geht dann in keiner App mehr. In Passwortfeldern setzt macOS solche Kurzbefehle aus, dort kommt dann „%@“ an.", keys, info.text, info.text)
            }
        }
        // [17] the Terminal's control keys
        if let n = hit(code, mods, ["terminal"]) {
            if n.kind == .terminalRefuse {
                return refuse(L("%@ %@ (im Terminal, auch in Claude Code und VS Code). Als Kurzbefehl ginge das dort verloren. Nimm eine andere Kombination.", keys, n.text))
            }
            note = note ?? L("Hinweis: %@ %@ (im Terminal, auch in iTerm und VS Code). Dort geht das dann nicht mehr.", keys, n.text)
        }
        // [18] common apps and services
        if let n = hit(code, mods, ["common-apps"]) {
            note = note ?? L("Hinweis: %@ %@. Das geht dann nicht mehr.", keys, n.text)
        }
        // [19] ⇧⌘ or ⌥⌘ with a letter nobody names
        if note == nil, mods == shift | cmd || mods == option | cmd, let token = menuToken(code), token.count == 1,
           token.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
            note = L("Hinweis: ⇧⌘ und ⌥⌘ mit einem Buchstaben nutzen viele Apps für eigene Menübefehle. Ob eine App %@ belegt, kann VoiceBud nicht nachsehen. Falls ja, geht es dort nicht mehr.", keys)
        }
        // [20] VoiceOver's keys
        if note == nil, mods & (control | option) == control | option, NSWorkspace.shared.isVoiceOverEnabled {
            note = L("Hinweis: VoiceOver nutzt ⌃⌥ als VO-Taste. Solange VoiceOver an ist, kann %@ dort einen VoiceOver-Befehl ersetzen.", keys)
        }
        // [16] F1-F12 on Apple keyboards
        if note == nil, topRow.contains(code) {
            note = L("Hinweis: Auf Apple-Tastaturen drückst du für %@ fn mit, solange die F-Tasten nicht als Standard-Funktionstasten eingestellt sind (Systemeinstellungen > Tastatur > Tastaturkurzbefehle > Funktionstasten).", keys)
        }
        return .take(.key(combo), note: note)
    }

    /// a character that is needed and cannot be typed another way (an ASCII sign, €, typographic marks)
    private static func needed(_ ch: String, besides code: UInt16) -> Bool {
        for other in UInt16(0)..<128 where !editingKeys.contains(other) {
            if typed(other, mods: 0) == ch || typed(other, mods: shift) == ch { return false }
        }
        let marks = "€„“”‚‘’–—…»«›‹"
        return ch.unicodeScalars.allSatisfy { ($0.isASCII && !CharacterSet.alphanumerics.contains($0)) || marks.unicodeScalars.contains($0) }
    }

    /// the same accent from another key without ⌥ (then this one is not the only way to type it)
    private static func deadElsewhere(_ accent: String, besides code: UInt16) -> Bool {
        for other in UInt16(0)..<128 where !editingKeys.contains(other) {
            for m in [UInt32(0), shift] where (other, m) != (code, 0) {
                if let info = typedInfo(other, mods: m), info.dead, info.text == accent { return true }
            }
        }
        return false
    }

    /// a free variant on the same key: ⌃⌥⌘, ⌃⇧⌘, ⌥⇧⌘, ⌃⌥⇧⌘, the first one with nothing to say
    static func suggestion(code: UInt16, target: String, others: [String: Shortcut], system: [SystemEntry]) -> KeyCombo? {
        if editingKeys.contains(code) || mediaKeys.contains(code) { return nil }
        for mods in [control | option | cmd, control | shift | cmd, option | shift | cmd, control | option | shift | cmd] {
            if case .take(.key(let k), nil) = judgeKey(code: code, mods: mods, target: target, others: others, system: system) { return k }
        }
        return nil
    }

    /// modifiers alone ("ctrl+shift", "cmd_r"): the core watches them
    static func judgeChord(_ spec: String, target: String, others: [String: Shortcut]) -> Verdict {
        let names = spec.split(separator: "+").map(String.init)
        if names.count == 1 && !names[0].hasSuffix("_r") {
            return .refuse(target == "command" ? L("Eine Taste allein links steckt in fast jedem Kurzbefehl. Nimm zwei Sondertasten.")
                           : L("Eine Taste allein links steckt in fast jedem Kurzbefehl. Nimm zwei Sondertasten oder eine rechts."))
        }
        if names == ["alt_r"] && target == "ocr" {
            return .refuse(L("⌥ schaltet in der Texterkennung auf Formeln um. Nimm eine andere Taste."))
        }
        if names.count == 1 && target == "command" {
            return .refuse(L("Befehl startet schon beim Drücken. Mit %@ allein würde jeder Kurzbefehl mit dieser Taste eine Aufnahme starten. Nimm zwei Sondertasten.", HotkeyFormat.display(spec)))
        }
        let mine = familySet(spec)
        if let why = clash(.chord(spec), target: target, others: others) { return .refuse(why) }
        // pairs that begin shortcuts macOS takes for itself: the core may never see the last key, and
        // a toggle would start on the release (the held command starts at once anyway)
        if target != "command", let example = systemStarts[mine] {
            return .refuse(L("Mit %@ beginnen Kurzbefehle von macOS (etwa %@), dabei würde VoiceBud mitstarten. Nimm eine andere Kombination.",
                             HotkeyFormat.display(spec), Loc.shared.english ? example.en : example.de))
        }
        // [23] one right-hand key alone: a click with it held toggles too, and macOS dictation can sit
        // on a double press of ⌘ or ⌃
        if names.count == 1 {
            let key = HotkeyFormat.display(spec)
            if names[0] == "cmd_r" || names[0] == "ctrl_r" {
                return .take(.chord(spec), note: L("Hinweis: Ein Mausklick mit gedrückter Taste %@ schaltet ebenfalls um. Und ist bei der Diktierfunktion von macOS das zweimalige Drücken dieser Taste eingestellt, startet sie mit (Systemeinstellungen > Tastatur > Diktierfunktion).", key))
            }
            return .take(.chord(spec), note: L("Hinweis: Ein Mausklick mit gedrückter Taste %@ schaltet ebenfalls um.", key))
        }
        return .take(.chord(spec), note: nil)
    }

    static let systemStarts: [Set<String>: (de: String, en: String)] = [
        ["shift", "cmd"]: ("⇧⌘4 für Bildschirmfotos", "⇧⌘4 for screenshots"),
        ["alt", "cmd"]: ("⌥⌘Esc für Sofort beenden", "⌥⌘Esc for Force Quit"),
        ["ctrl", "cmd"]: ("⌃⌘Q zum Sperren", "⌃⌘Q to lock the screen"),
        ["ctrl", "shift", "cmd"]: ("⌃⇧⌘4 für Bildschirmfotos in die Zwischenablage", "⌃⇧⌘4 for screenshots to the clipboard"),
        ["alt", "shift", "cmd"]: ("⌥⇧⌘Esc zum sofortigen Beenden", "⌥⇧⌘Esc to force quit"),
    ]

    /// another mode's shortcut in the way, with why (nil: none). The same keys; a chord the key's
    /// or chord's modifiers would complete on the way (that one starts too, the core may never see the
    /// key: only an exactly equal set, a longer one spoils it, see PushToTalk.strict); and anything
    /// containing the held command's chord, which starts at the first moment it is complete.
    static func clash(_ s: Shortcut, target: String, others: [String: Shortcut]) -> String? {
        let mine: Set<String>
        switch s {
        case .chord(let spec): mine = familySet(spec)
        case .key(let k): mine = k.families
        }
        // a fixed order, the same keys first (the reason shown must not depend on a dictionary's order)
        let order = ["dictate", "prompt", "command", "ocr"].filter { $0 != target && others[$0] != nil }
        for mode in order {
            guard let other = others[mode] else { continue }
            switch (s, other) {
            case (.key(let a), .key(let b)) where a.key == b.key && a.mods == b.mods:
                return L("Das ist schon der Kurzbefehl für %@", name(mode))
            case (.chord, .chord(let spec)) where familySet(spec) == mine:
                return L("Das ist schon der Kurzbefehl für %@", name(mode))
            default:
                break
            }
        }
        for mode in order {
            guard let other = others[mode] else { continue }
            switch (s, other) {
            case (.key, .chord(let spec)) where familySet(spec) == mine && !mine.isEmpty:
                // macOS takes the key, the core may never see it: that chord would start along
                return L("%@ startet schon mit %@ allein und würde bei dieser Kombination mitstarten. Nimm andere Sondertasten.",
                         name(mode), HotkeyFormat.display(spec))
            case (.chord(let spec), .key(let k)) where k.families == mine:
                return L("Der Kurzbefehl für %@ (%@) beginnt mit %@, VoiceBud würde dabei mitstarten. Nimm eine andere Kombination.",
                         name(mode), k.display, HotkeyFormat.display(spec))
            default:
                break
            }
            // the held command starts the moment its chord is complete
            if mode == "command", case .chord(let spec) = other, familySet(spec).isStrictSubset(of: mine) {
                return L("Befehl (%@) steckt darin und würde jedes Mal kurz mitstarten, nimm eine andere Kombination", HotkeyFormat.display(spec))
            }
            if target == "command", case .chord = s {
                let theirs: Set<String>
                switch other {
                case .chord(let spec): theirs = familySet(spec)
                case .key(let k): theirs = k.families
                }
                if mine.isStrictSubset(of: theirs) {
                    return L("Das steckt in %@ (%@), Befehl würde dort jedes Mal kurz mitstarten. Nimm eine andere Kombination.",
                             name(mode), HotkeyFormat.display(other.spec))
                }
            }
        }
        return nil
    }

    static func familySet(_ spec: String) -> Set<String> {
        Set(spec.lowercased().split(separator: "+").map { part in
            let k = part.trimmingCharacters(in: .whitespaces)
            return k.hasSuffix("_l") || k.hasSuffix("_r") ? String(k.dropLast(2)) : k
        })
    }

    static func name(_ mode: String) -> String {
        switch mode {
        case "dictate": return L("Diktat")
        case "prompt": return L("Prompt")
        case "command": return L("Befehl")
        case "ocr": return L("Texterkennung")
        default: return mode
        }
    }
}
