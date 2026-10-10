// `--render <dir>` for the hub: PNGs (scale 2, light and dark) of every pane, drawn headless with
// ImageRenderer from in-memory sample data. Never reads the real history DB or writes any file
// except the PNGs.
import AppKit
import SwiftUI

/// Writes hub-<pane>-<light|dark>.png into `dir`. Must run on the main thread.
func renderHubPanes(to dir: URL) throws {
    try MainActor.assumeIsolated { try HubRenderer.renderAll(to: dir) }
}

enum HubRenderError: Error, CustomStringConvertible {
    case noImage(String)
    var description: String {
        switch self { case .noImage(let name): return "ImageRenderer produced no image for \(name)" }
    }
}

@MainActor
enum HubRenderer {
    private struct Shot {
        let name: String
        let pane: HubPane
        var settings: (inout UISettings) -> Void = { _ in }
        var empty = false
        var height: CGFloat = 620
        var prepare: (HubModel) -> Void = { _ in }
    }

    private static let shots: [Shot] = [
        Shot(name: "verlauf", pane: .verlauf),
        Shot(name: "verlauf-leer", pane: .verlauf, empty: true),
        Shot(name: "woerterbuch", pane: .woerterbuch),
        Shot(name: "insel", pane: .insel),
        Shot(name: "insel-live", pane: .insel, settings: { $0.islandStyle = .insel; $0.liveText = true }),
        Shot(name: "insel-kapsel", pane: .insel, settings: { $0.islandStyle = .kapsel; $0.confirmSeconds = 2.5 }),
        Shot(name: "insel-kapsel-live", pane: .insel, settings: { $0.islandStyle = .kapsel; $0.liveText = true }),
        Shot(name: "welle", pane: .welle),
        Shot(name: "welle-linie", pane: .welle, settings: { $0.waveStyle = .linie; $0.waveLive = false }),
        Shot(name: "alcove", pane: .alcove),
        Shot(name: "alcove-uebernehmen", pane: .alcove, settings: { $0.alcove = .takeover }),
        Shot(name: "alcove-ausweichen", pane: .alcove, settings: { $0.alcove = .dodge }),
        Shot(name: "kontext", pane: .kontext, settings: { $0.contextApps = ["com.apple.mail": 3] }),
        Shot(name: "kuerzel", pane: .kuerzel),
        Shot(name: "erkennung", pane: .erkennung),
        Shot(name: "allgemein", pane: .allgemein),
        // the Kurzbefehle at the end of Allgemein (10.10.): one row recording, one changed
        Shot(name: "kurzbefehle-aufnahme", pane: .allgemein, settings: { $0.shortcuts = ["dictate": .chord("cmd_r")] },
             height: 1560, prepare: { m in
                 m.state.hotkeys = ["dictate": "cmd_r", "prompt": "ctrl+alt", "command": "ctrl+cmd"]
                 let r = HubShortcutRecorder()
                 r.preview(target: "prompt", live: ["⌃", "⌥"])
                 m.previewRecorder = r
             }),
        Shot(name: "kurzbefehle-hinweis", pane: .allgemein,
             settings: { $0.shortcuts = ["ocr": .key(KeyCombo(key: 17, mods: 2048 | 256, label: "⌥⌘T")),
                                         "prompt": .key(KeyCombo(key: 13, mods: 4096, label: "⌃W"))] },
             height: 1560, prepare: { m in
                 m.state.hotkeys = ["dictate": "ctrl+shift", "prompt": "label:⌃W", "command": "ctrl+cmd"]
                 let r = HubShortcutRecorder()
                 r.preview(target: "dictate",
                           problem: .init(target: "dictate",
                                          text: L("%@ %@, und das in fast jeder App. Als Kurzbefehl von VoiceBud ginge das überall verloren. Nimm ⌃, ⌥ oder ⇧ dazu.",
                                                  "⌘W", Loc.shared.english ? "closes the window" : "schließt das Fenster"),
                                          keys: ["⌘", "W"], suggestion: KeyCombo(key: 13, mods: 2048 | 512 | 256, label: "⌥⇧⌘W")),
                           note: .init(target: "prompt", text: L("Hinweis: %@ %@ (im Terminal, auch in iTerm und VS Code). Dort geht das dann nicht mehr.", "⌃W",
                                      Loc.shared.english ? "deletes the word before the cursor" : "löscht das Wort vor dem Cursor")))
                 m.previewRecorder = r
             }),
    ]

    static func renderAll(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for shot in shots {
            for scheme in [ColorScheme.light, .dark] {
                let model = makeModel(shot)
                let view = HubRenderBoard(scheme: scheme) {
                    HubStaticWindow(model: model, size: CGSize(width: 900, height: shot.height))
                }
                let file = dir.appendingPathComponent("hub-\(shot.name)-\(scheme == .dark ? "dark" : "light").png")
                try write(view, scheme: scheme, to: file)
            }
        }
    }

    private static func write<V: View>(_ view: V, scheme: ColorScheme, to url: URL) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).environment(\.hubStatic, true))
        renderer.scale = 2
        renderer.isOpaque = false
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { throw HubRenderError.noImage(url.lastPathComponent) }
        try png.write(to: url, options: .atomic)
    }

    private static func makeModel(_ shot: Shot) -> HubModel {
        let state = AppState()
        var settings = UISettings()
        shot.settings(&settings)
        state.settings = settings
        let entries = shot.empty ? [] : sampleEntries()
        let model = HubModel(previewState: state,
                             entries: entries,
                             stats: shot.empty ? HistoryStats() : HistoryStats(words: 412, count: 14, avgSeconds: 0.8),
                             total: shot.empty ? 0 : 1284,
                             terms: sampleTerms)
        model.pane = shot.pane
        model.previewAlcoveRunning = true
        shot.prepare(model)
        if let first = entries.first {
            model.previewHover = first.id
            model.previewExpanded = [first.id]
        }
        model.previewHoverTerm = "myPACE"
        model.previewSnippets = Loc.shared.english
            ? [["trigger": "my signature", "text": "Best regards\nAlex Weber\nProduct Team"],
               ["trigger": "my address", "text": "Hauptstraße 12, 60311 Frankfurt am Main"]]
            : [["trigger": "meine Signatur", "text": "Viele Grüße\nAlex Weber\nProduktteam"],
               ["trigger": "meine Adresse", "text": "Hauptstraße 12, 60311 Frankfurt am Main"]]
        return model
    }

    // the samples follow the UI language (05.10.: the README shows the English app)
    private static var sampleTerms: [String] { Loc.shared.english
        ? ["AI slop", "shadcn", "FS-SC", "Alvantiq", "myPACE", "ACAR", "repo", "slides",
           "Excel sheet", "to-do list", "deadline", "feedback", "deploy"]
        : ["AI-Slop", "shadcn", "FS-SC", "Alvantiq", "myPACE", "ACAR", "Repo", "Slides",
           "Excel-Sheet", "To-do-Liste", "Deadline", "Feedback", "deployen"] }

    private static func sampleEntries() -> [HistoryEntry] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func at(_ dayOffset: Int, _ h: Int, _ m: Int) -> Date {
            cal.date(byAdding: DateComponents(day: dayOffset, hour: h, minute: m), to: today) ?? today
        }
        func words(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }
        let german: [(Date, Mode, String, String, String, Double)] = [
            (at(0, 9, 41), .dictate, "Mail",
             "Hallo Frau Becker, vielen Dank für die schnelle Rückmeldung. Den Termin am Freitag kann ich leider nicht wahrnehmen. Würde Ihnen Montag um 10 Uhr passen?",
             "ähm hallo frau becker vielen dank für die schnelle rückmeldung den termin am donnerstag nein ich meine freitag kann ich leider nicht so wahrnehmen würde ihnen halt montag um 10 uhr passen",
             0.7),
            (at(0, 9, 15), .prompt, "Claude",
             "Rolle: Du bist ein erfahrener Motion-Designer. Aufgabe: Überarbeite die Endkarte von Video 1.2, sodass sie exakt dem Serienlayout aus 1.1 entspricht. Achte auf Abstände, Schriftgrößen und das Timing der Einblendung.",
             "okay also du bist motion designer und sollst die endkarte von video eins punkt zwei überarbeiten dass sie genau wie das serienlayout aus eins eins aussieht also abstände schriftgrößen und das timing",
             1.9),
            (at(0, 8, 58), .dictate, "Slack",
             "Bin in 5 Minuten da, fangt schon mal ohne mich an.",
             "bin in fünf minuten da fangt schon mal ohne mich an",
             0.3),
            (at(-1, 18, 22), .dictate, "Notizen",
             "Einkauf fürs Wochenende: Kaffeebohnen (Single Origin), Hafermilch, Brot vom Bäcker.",
             "äh einkauf fürs wochenende kaffeebohnen single origin hafermilch und brot vom bäcker",
             0.4),
            (at(-1, 16, 5), .dictate, "Nachrichten",
             "Klingt gut, ich bring den Beamer mit.",
             "klingt gut ich bring den beamer mit",
             0.3),
            (at(-1, 11, 12), .prompt, "Claude",
             "Fasse das Protokoll der Vollversammlung in fünf Stichpunkten zusammen und markiere offene Entscheidungen.",
             "kannst du mir das protokoll von der vollversammlung in fünf stichpunkten zusammenfassen und die offenen entscheidungen markieren",
             1.2),
        ]
        let english: [(Date, Mode, String, String, String, Double)] = [
            (at(0, 9, 41), .dictate, "Mail",
             "Hi Ms Becker, thanks for the quick reply. Unfortunately I can't make the meeting on Friday. Would Monday at 10 am work for you?",
             "uhm hi ms becker thanks for the quick reply unfortunately i can't make the meeting on thursday no i mean friday would monday at 10 am work for you",
             0.7),
            (at(0, 9, 15), .prompt, "Claude",
             "Role: You are an experienced motion designer. Task: Revise the end card of video 1.2 so it matches the series layout from 1.1 exactly. Pay attention to spacing, type sizes and the timing of the fade-in.",
             "okay so you're a motion designer and you should revise the end card of video one point two so it looks exactly like the series layout from one one so spacing type sizes and the timing",
             1.9),
            (at(0, 8, 58), .dictate, "Slack",
             "Be there in 5 minutes, go ahead and start without me.",
             "be there in five minutes go ahead and start without me",
             0.3),
            (at(-1, 18, 22), .dictate, "Notes",
             "Weekend shopping: coffee beans (single origin), oat milk, bread from the bakery.",
             "uh weekend shopping coffee beans single origin oat milk and bread from the bakery",
             0.4),
            (at(-1, 16, 5), .dictate, "Messages",
             "Sounds good, I'll bring the projector.",
             "sounds good i'll bring the projector",
             0.3),
            (at(-1, 11, 12), .prompt, "Claude",
             "Summarise the minutes of the general assembly in five bullet points and mark open decisions.",
             "can you summarise the minutes from the general assembly in five bullet points and mark the open decisions",
             1.2),
        ]
        let rows = Loc.shared.english ? english : german
        return rows.enumerated().map { idx, r in
            HistoryEntry(id: Int64(100 - idx), date: r.0, mode: r.1, app: r.2, raw: r.4, final: r.3,
                         lang: Loc.shared.english ? "en" : "de", audioSeconds: nil, totalSeconds: r.5, words: words(r.3))
        }
    }
}

/// Neutral board around the window, like the concept page, so renders read as a window on a desk.
private struct HubRenderBoard<Content: View>: View {
    let scheme: ColorScheme
    let content: Content

    init(scheme: ColorScheme, @ViewBuilder content: () -> Content) {
        self.scheme = scheme
        self.content = content()
    }

    var body: some View {
        content
            .compositingGroup()
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 24, y: 14)
            .padding(36)
            .background(scheme == .dark ? Color(hex: 0x111113) : Color(hex: 0xF3F2EF))
    }
}

// `--selftest-shortcuts`: the shortcut recorder and its rules fed with made-up key events (no real
// keys reach the system, nothing is written). Prints one line per case to stderr.
extension HubShortcutRecorder {
    static func selfTest() -> Bool {
        let ctrlL: UInt = 0x1, ctrlR: UInt = 0x2000, altL: UInt = 0x20, altR: UInt = 0x40
        let shiftL: UInt = 0x2, cmdL: UInt = 0x8, cmdR: UInt = 0x10
        let fam: [UInt: UInt] = [ctrlL: 1 << 18, ctrlR: 1 << 18, altL: 1 << 19, altR: 1 << 19,
                                 shiftL: 1 << 17, 0x4: 1 << 17, cmdL: 1 << 20, cmdR: 1 << 20]
        let C = ShortcutRules.cmd, S = ShortcutRules.shift, O = ShortcutRules.option, K = ShortcutRules.control
        func flags(_ bits: UInt) -> NSEvent {
            var raw = bits
            for (b, f) in fam where bits & b != 0 { raw |= f }
            return NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: raw),
                                    timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: 0)!
        }
        func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        var failed = 0
        func check(_ name: String, _ got: String?, _ want: String?) {
            let ok = got == want
            if !ok { failed += 1 }
            FileHandle.standardError.write("\(ok ? "ok  " : "FAIL") \(name): \(got ?? "nil")\(ok ? "" : " (want \(want ?? "nil"))")\n".data(using: .utf8)!)
        }
        func show(_ s: Shortcut?) -> String? {
            switch s {
            case .chord(let c)?: return c
            case .key(let k)?: return "\(k.label) \(k.key) \(k.mods)"
            case nil: return nil
            }
        }
        let standard = ["dictate": "ctrl+shift", "prompt": "ctrl+alt", "command": "ctrl+cmd"]
        // macOS's list as the tests assume it: screenshots on, Spaces arrows on, the Zoom keys off
        let system: [ShortcutRules.SystemEntry] = [
            .init(code: 21, mods: S | C, enabled: true), .init(code: 20, mods: S | C, enabled: true),
            .init(code: 49, mods: C, enabled: true), .init(code: 123, mods: K, enabled: true),
            .init(code: 28, mods: O | C, enabled: false), .init(code: 103, mods: 0, enabled: true),
        ]
        var lastNote: String?
        var lastSuggestion: String?
        func run(_ target: String, hotkeys: [String: String] = standard, own: [String: Shortcut] = [:],
                 _ events: [NSEvent]) -> (got: String?, problem: String?) {
            let state = AppState()
            state.hotkeys = hotkeys
            state.settings.shortcuts = own
            let model = HubModel(previewState: state, entries: [], stats: HistoryStats(), total: 0, terms: [])
            let r = HubShortcutRecorder()
            r.testBegin(target, model: model, system: system)
            for e in events { r.handle(e) }
            lastNote = r.note?.text
            lastSuggestion = r.problem?.suggestion?.label
            return (show(state.settings.shortcuts[target]), r.problem?.text)
        }
        func up(_ code: UInt16, _ mods: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        func fn(_ down: Bool) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? .function : [], timestamp: 0, windowNumber: 0,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 63)!
        }
        let verbose = ProcessInfo.processInfo.environment["VOICEBUD_SELFTEST_VERBOSE"] != nil
        func refused(_ r: (got: String?, problem: String?)) -> String {
            if verbose, let p = r.problem { FileHandle.standardError.write("     → \(p)\n".data(using: .utf8)!) }
            return r.got == nil && r.problem != nil ? "refused" : "taken \(r.got ?? "-")"
        }
        // modifiers alone: the most that was held, on release
        check("alt then alt+shift", run("dictate", [flags(altL), flags(altL | shiftL), flags(shiftL), flags(0)]).got, "alt+shift")
        check("right cmd alone", run("dictate", [flags(cmdR), flags(0)]).got, "cmd_r")
        check("three modifiers", run("prompt", [flags(ctrlL), flags(ctrlL | shiftL), flags(ctrlL | shiftL | altL), flags(0)]).got,
              "ctrl+alt+shift")
        check("left cmd alone refused", refused(run("dictate", [flags(cmdL), flags(0)])), "refused")
        check("prompt's keys refused", refused(run("dictate", [flags(ctrlL), flags(ctrlL | altL), flags(0)])), "refused")
        check("same keys as before: nothing stored", run("dictate", [flags(ctrlL), flags(ctrlL | shiftL), flags(0)]).got, nil)
        check("chord over the held command refused", refused(run("dictate", [flags(ctrlL), flags(ctrlL | cmdL), flags(ctrlL | cmdL | shiftL), flags(0)])), "refused")
        check("command inside a toggle chord refused", refused(run("command", [flags(ctrlR), flags(0)])), "refused")
        check("right cmd alone refused for the held command", refused(run("command", [flags(cmdR), flags(0)])), "refused")
        check("the set held together, not all touched", run("dictate", own: ["prompt": .chord("alt_r")],
                                                          [flags(ctrlL), flags(ctrlL | shiftL), flags(ctrlL), flags(ctrlL | altL), flags(0)]).got,
              "ctrl+alt")
        check("shift+cmd refused (text recognition starts so)", refused(run("dictate", [flags(shiftL), flags(shiftL | cmdL), flags(0)])), "refused")
        check("alt+cmd refused for dictation (macOS)", refused(run("dictate", [flags(altL), flags(altL | cmdL), flags(0)])), "refused")
        check("alt+cmd fine for the held command", run("command", [flags(altL), flags(altL | cmdL), flags(0)]).got, "alt+cmd")
        check("a chord for the text recognition", run("ocr", [flags(ctrlL), flags(ctrlL | altL | shiftL), flags(0)]).got, "ctrl+alt+shift")
        check("Esc cancels", run("dictate", [flags(ctrlL), key(53, []), flags(ctrlL | altL), flags(0)]).got, nil)
        // keys with modifiers: taken on the key
        check("ctrl+W for dictation", run("dictate", [flags(ctrlL), key(13, .control), flags(0)]).got, "⌃W 13 \(K)")
        check("ctrl+W carries the Terminal note", lastNote == nil ? nil : "note", "note")
        let w = run("dictate", [flags(ctrlL), key(13, .control), flags(0)])
        check("ctrl+W is no chord afterwards", w.problem, nil)
        check("ctrl+option+D", run("prompt", hotkeys: ["dictate": "ctrl+shift", "prompt": "ctrl+alt"], own: ["prompt": .chord("cmd_r")],
                                   [key(2, [.control, .option])]).got, "⌃⌥D 2 \(K | O)")
        check("ctrl+option+D refused while the prompt is ctrl+option", refused(run("dictate", [key(2, [.control, .option])])), "refused")
        check("ctrl+option+cmd+D refused (contains the held command's ctrl+cmd)", refused(run("dictate", [key(2, [.control, .option, .command])])), "refused")
        check("ctrl+option+shift+K taken next to the prompt's ctrl+option (strict in the core)",
              run("dictate", [key(40, [.control, .option, .shift])]).got, "⌃⌥⇧K 40 \(K | O | S)")
        for target in ["dictate", "prompt", "command", "ocr"] {
            let r = run(target, [key(2, [.option, .shift, .command])])
            check("option+shift+cmd+D on \(target) without a note", "\(r.got ?? "-") \(lastNote == nil)", "⌥⇧⌘D 2 \(O | S | C) true")
        }
        check("a chord equal to another mode's key modifiers refused",
              refused(run("dictate", own: ["ocr": .key(KeyCombo(key: 17, mods: O | S | C, label: "⌥⇧⌘T"))],
                          [flags(altL), flags(altL | shiftL), flags(altL | shiftL | cmdL), flags(0)])), "refused")
        check("cmd+W refused", refused(run("dictate", [key(13, .command)])), "refused")
        check("cmd+W offers a free variant (not one with the command's ctrl+cmd)", lastSuggestion, "⌥⇧⌘W")
        check("cmd+J refused (any cmd+key)", refused(run("dictate", [key(38, .command)])), "refused")
        check("W alone refused", refused(run("dictate", [key(13, [])])), "refused")
        check("shift+W refused", refused(run("dictate", [key(13, .shift)])), "refused")
        check("ctrl+A refused (text)", refused(run("dictate", [key(0, .control)])), "refused")
        check("ctrl+shift+A refused (text selection)", refused(run("dictate", [key(0, [.control, .shift])])), "refused")
        check("ctrl+C refused (Terminal)", refused(run("dictate", [key(8, .control)])), "refused")
        check("ctrl+left refused (Spaces on)", refused(run("dictate", [key(123, .control)])), "refused")
        check("option+left refused (text)", refused(run("dictate", [key(123, .option)])), "refused")
        check("ctrl+option+left refused while the prompt is ctrl+option", refused(run("dictate", [key(123, [.control, .option])])), "refused")
        check("ctrl+option+shift+left taken with a note", run("dictate", [key(123, [.control, .option, .shift])]).got, "⌃⌥⇧← 123 \(K | O | S)")
        check("the arrow note", lastNote == nil ? nil : "note", "note")
        check("shift+cmd+4 refused (on in macOS)", refused(run("ocr", [key(21, [.shift, .command])])), "refused")
        check("option+cmd+8 taken with a note (Zoom off here)", run("dictate", [key(28, [.option, .command])]).got, "⌥⌘8 28 \(O | C)")
        check("the Zoom note says it is off", lastNote?.contains(Loc.shared.english ? "off on your Mac" : "Bei dir ist er aus") == true ? "off" : lastNote, "off")
        check("ctrl+cmd+Q refused (always macOS)", refused(run("dictate", [key(12, [.control, .command])])), "refused")
        check("F11 refused (on in macOS)", refused(run("dictate", [key(103, [])])), "refused")
        check("F13 alone", run("dictate", [key(105, [])]).got, "F13 105 0")
        check("F5 alone with the fn note", run("dictate", [key(96, [])]).got, "F5 96 0")
        check("option+shift+F5 taken", run("dictate", [key(96, [.option, .shift])]).got, "⌥⇧F5 96 \(O | S)")
        check("space alone refused", refused(run("dictate", [key(49, [])])), "refused")
        check("cmd+space refused", refused(run("dictate", [key(49, .command)])), "refused")
        check("volume key refused", refused(run("dictate", [key(72, [])])), "refused")
        check("two regular keys refused", refused(run("dictate", [key(13, []), key(1, [])])), "refused")
        check("fn alone refused", refused(run("dictate", [fn(true), fn(false)])), "refused")
        check("fn with a letter refused", refused(run("dictate", [fn(true), key(13, .function)])), "refused")
        check("a release whose press macOS took", refused(run("dictate", [up(49, .command)])), "refused")
        check("same key as the text recognition refused", refused(run("dictate", own: ["ocr": .key(KeyCombo(key: 17, mods: K | C, label: "⌃⌘T"))],
                                                                     [key(17, [.control, .command])])), "refused")
        check("option+cmd+T for the text recognition (note: common apps)", run("ocr", [key(17, [.option, .command])]).got, "⌥⌘T 17 \(O | C)")
        check("standard key for the recognition is stored as none", run("ocr", own: ["ocr": .chord("ctrl+alt+shift")],
                                                                        [key(19, [.shift, .command])]).got, nil)
        check("ctrl+cmd+F5 refused while the command is ctrl+cmd", refused(run("ocr", [key(96, [.control, .command])])), "refused")
        check("shift+cmd+F5", run("ocr", [key(96, [.shift, .command])]).got, "⇧⌘F5 96 \(S | C)")
        // ⌥ alone with a key that types: needed characters refused, rare ones noted
        if ShortcutRules.typed(37, mods: O) == "@" {
            check("option+L (@ on German) refused", refused(run("dictate", [key(37, .option)])), "refused")
        }
        if ShortcutRules.typed(6, mods: O) == "¥" || ShortcutRules.typed(16, mods: O) == "¥" {
            let code: UInt16 = ShortcutRules.typed(6, mods: O) == "¥" ? 6 : 16
            check("option+Y (¥) taken with a note", run("dictate", [key(code, .option)]).got.map { _ in "taken" }, "taken")
            check("the ¥ note names the character", lastNote?.contains("¥") == true ? "named" : lastNote, "named")
        }
        // "Standard" and "Rückgängig" are checked like a new shortcut
        do {
            let state = AppState()
            state.hotkeys = standard
            state.settings.shortcuts = ["ocr": .key(KeyCombo(key: 96, mods: S | C, label: "⇧⌘F5")),
                                        "dictate": .key(KeyCombo(key: 19, mods: S | C, label: "⇧⌘2"))]
            let model = HubModel(previewState: state, entries: [], stats: HistoryStats(), total: 0, terms: [])
            let r = HubShortcutRecorder()
            r.restore("ocr", to: nil, model: model)
            check("Standard refused while dictation holds shift+cmd+2", "\(show(state.settings.shortcuts["ocr"]) ?? "nil") \(r.problem != nil)",
                  "⇧⌘F5 96 \(S | C) true")
            r.restore("dictate", to: nil, model: model)
            check("Standard for dictation", show(state.settings.shortcuts["dictate"]), nil)
            r.restore("ocr", to: nil, model: model)
            check("then Standard for the recognition", show(state.settings.shortcuts["ocr"]), nil)
        }
        if let dead = ShortcutRules.typedInfo(45, mods: O), dead.dead, dead.text == "~" {
            check("option+N (the only ~ on German) refused", refused(run("dictate", [key(45, .option)])), "refused")
        }
        // judged against the standard, not the core's stale report while a row records
        do {
            let state = AppState()
            state.hotkeys = ["dictate": "ctrl+shift", "prompt": "alt_r", "command": "ctrl+cmd"]   // stale: prompt was reset
            state.hotkeyStandard = standard
            let model = HubModel(previewState: state, entries: [], stats: HistoryStats(), total: 0, terms: [])
            let r = HubShortcutRecorder()
            r.testBegin("dictate", model: model, system: system)
            for e in [flags(ctrlL), flags(ctrlL | altL), flags(0)] { r.handle(e) }
            check("prompt's standard ctrl+alt counts, not the stale report", r.problem == nil ? "taken" : "refused", "refused")
        }
        check("right option alone refused for the text recognition", refused(run("ocr", [flags(altR), flags(0)])), "refused")
        check("cmd+left gets the text reason", (run("dictate", [key(123, .command)]).problem ?? "").contains(Loc.shared.english ? "text field" : "Textfeld") ? "text" : "other", "text")
        var reasons = Set<String>()
        for _ in 0..<6 {
            reasons.insert(run("dictate", own: ["ocr": .key(KeyCombo(key: 17, mods: K | C, label: "⌃⌘T"))], [key(17, [.control, .command])]).problem ?? "")
        }
        check("the same reason every time", "\(reasons.count)", "1")
        // right-hand keys alone: a note about macOS dictation
        _ = run("dictate", [flags(cmdR), flags(0)])
        check("right cmd alone notes macOS dictation", lastNote == nil ? nil : "note", "note")
        // the layout: what a key types
        check("German or US layout gives a character for option+L", ShortcutRules.typed(37, mods: O) == nil ? nil : "char", "char")
        check("ctrl+L types nothing", ShortcutRules.typed(37, mods: K), nil)
        check("caps of a label", HubFormat.keyCaps("⌃⌥D").joined(separator: " "), "⌃ ⌥ D")
        check("label spec", HubFormat.hotkey("label:⌃W").joined(separator: " "), "⌃ W")
        // a recognition key with ⌥ in it: letting go of it is no tap, the next real tap is
        var taps = ScreenText.OptionTaps(shortcutHasOption: true)
        let first = [taps.feed(.option), taps.feed([])].contains(true)
        let second = [taps.feed(.option), taps.feed([])].last!
        check("⌥ of the shortcut is no tap", "\(first) \(second)", "false true")
        var plain = ScreenText.OptionTaps()
        check("plain tap", "\([plain.feed(.option), plain.feed([])].last!)", "true")
        // the settings: chord as string, key as object, the first version's ocrHotkey read
        let json = #"{"shortcuts": {"dictate": "cmd_r", "prompt": {"key": 13, "mods": 4096, "label": "⌃W"}}, "ocrHotkey": {"key": 17, "mods": 2304, "label": "⌥⌘T"}}"#
        let decoded = try? JSONDecoder().decode(UISettings.self, from: Data(json.utf8))
        check("settings read", [show(decoded?.shortcuts["dictate"]), show(decoded?.shortcuts["prompt"]), show(decoded?.shortcuts["ocr"])]
              .map { $0 ?? "nil" }.joined(separator: " | "), "cmd_r | ⌃W 13 4096 | ⌥⌘T 17 2304")
        if let decoded, let data = try? JSONEncoder().encode(decoded),
           let again = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            check("settings written", "\((again["shortcuts"] as? [String: Any])?["dictate"] ?? "nil") \(again["ocrHotkey"] == nil)", "cmd_r true")
        } else {
            check("settings written", nil, "cmd_r true")
        }
        FileHandle.standardError.write("\(failed == 0 ? "all ok" : "\(failed) failed")\n".data(using: .utf8)!)
        return failed == 0
    }
}
