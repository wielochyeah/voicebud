// Shared contract for every VoiceBudUI source file. Existing API is fixed; additions only.
import AppKit
import SwiftUI

enum Phase: String, Codable { case idle, recording, processing, done, empty, error }
enum Mode: String, Codable { case dictate, prompt, command, ocr }
/// SPEC §0 (03.10.): the shape is "insel" or "kapsel"; live text is the separate `liveText`
/// switch. `kompakt` and `live` are the old values: they are still read (kompakt = insel,
/// live = insel + liveText) but never written.
enum IslandStyle: String, Codable, CaseIterable { case kompakt, live, kapsel, insel }
enum WaveStyle: String, Codable, CaseIterable { case fein, sym, linie }
enum AlcoveMode: String, Codable, CaseIterable { case auto, dodge, takeover }
/// the menu bar symbol while recording (MenuBarIcon.swift); "schlicht" is the plain microphone
enum MenuBarStyle: String, Codable, CaseIterable { case schlicht, farbe, punkt, zeit }
/// the app's own texts: as macOS (German if macOS is German, else English), or fixed (05.10.)
enum UILanguage: String, Codable, CaseIterable { case system, de, en }
/// what Whisper listens for: German or English decided per take (as before), or fixed
enum DictationLanguage: String, Codable, CaseIterable { case auto, de, en }

/// What the confirmation shows about the screen context of a take (done message "context").
/// Never the context itself: labels, counts and the names used.
struct ContextInfo: Equatable {
    var label: String
    var used: Bool
    var app: String
    var bundle: String
    var rows: [[String]]
    var warning: String?

    /// a hard rule withheld it, or the app changed: worth a word on the folded card
    var noteworthy: Bool {
        !used && ["Passwortfeld", "sichere Eingabe", "privates Fenster", "App ausgenommen", "App gewechselt"]
            .contains { label.hasSuffix($0) }
    }
}

struct DoneInfo: Equatable {
    var app: String
    var words: Int
    var seconds: Double
    var preview: String
    var toClipboard: Bool
    /// SPEC §0 (03.10.): the whole final text from the done message's "text" (shown when the
    /// pointer rests on the confirmation). Defaults to the preview.
    var fullText: String
    var context: ContextInfo?

    init(app: String, words: Int, seconds: Double, preview: String, toClipboard: Bool,
         fullText: String? = nil, context: ContextInfo? = nil) {
        self.context = context
        self.app = app
        self.words = words
        self.seconds = seconds
        self.preview = preview
        self.toClipboard = toClipboard
        self.fullText = fullText ?? preview
    }
}

@Observable
final class AppState {
    var phase: Phase = .idle
    var mode: Mode = .dictate
    /// 7 log-spaced band levels 0…1 from the microphone (only while recording)
    var bands: [Float] = Array(repeating: 0, count: 7)
    var rms: Float = 0
    /// full live transcript so far (replaced on every `partial` message)
    var partialText: String = ""
    var done: DoneInfo?
    var errorMessage: String?
    /// the error-phase card is a neutral notice with a check badge (Kontext-Probe: `"tone":"ok"`)
    var noticeOK = false
    /// processing: after how many seconds the island says "Dauert länger" (the core learns what is
    /// usual for this Mac and this take length; nil = the default 10 s)
    var hintAfter: Double?
    var recordingStarted: Date?
    var hotkeys: [String: String] = ["dictate": "ctrl+shift", "prompt": "ctrl+alt"]
    /// bumped on every `history_changed` message so views can reload
    var historyVersion: Int = 0
    var settings: UISettings = .load()
}

struct UISettings: Codable, Equatable {
    var islandStyle: IslandStyle = .insel
    var waveStyle: WaveStyle = .fein
    var waveLive: Bool = true
    var alcove: AlcoveMode = .auto
    var confirmSeconds: Double = 3.0
    var sounds: Bool = false
    var hideInFullscreen: Bool = false
    /// Texterkennung with ⇧⌘2 (off also frees the shortcut for other apps)
    var screenText: Bool = true
    /// recognised texts in their own history (Hub: Texterkennung)
    var screenTextHistory: Bool = true
    var keepModelsLoaded: Bool = false
    /// SPEC §0: live transcript while speaking (island drops down / capsule hangs a card).
    /// Off: compact island or plain capsule, and Python does not stream at all.
    var liveText: Bool = false
    /// SPEC §0 (03.10.): the pointer on a confirmation keeps it open and unfolds the whole text.
    var confirmHoverExpand: Bool = true
    /// KONTEXT-PLAN.md: 0 Aus, 1 Nur App, 2 Text am Cursor, 3 Ganzes Fenster; per-app overrides
    var contextLevel: Int = 2
    var contextApps: [String: Int] = [:]
    var contextElectron: Bool = true
    /// the first-run setup finished once (Python shows it again only while something is missing)
    var onboardingDone: Bool = false
    /// output muted while recording, except when one of these apps is in front or plays sound
    var muteWhileRecording: Bool = true
    var muteExceptions: [String] = ["com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos", "com.apple.FaceTime"]
    /// how the menu bar symbol shows a recording (05.10.: Schlicht, Farbe, Roter Punkt, Zeit)
    var menuBarStyle: MenuBarStyle = .schlicht
    /// new installs: English texts and automatic dictation (recommended: German or English per
    /// take, short takes German), chosen in the first setup step (05.10.); an install from before
    /// the setting keeps German texts
    var uiLanguage: UILanguage = .system
    var dictationLanguage: DictationLanguage = .auto

    enum CodingKeys: String, CodingKey {
        case islandStyle, waveStyle, waveLive, alcove, confirmSeconds, sounds, hideInFullscreen, screenText, screenTextHistory,
             keepModelsLoaded, liveText, confirmHoverExpand, contextLevel, contextApps, contextElectron,
             onboardingDone, muteWhileRecording, muteExceptions, menuBarStyle, uiLanguage, dictationLanguage
    }

    init() {}

    // Missing or malformed keys fall back to defaults instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UISettings()
        let style = (try? c.decodeIfPresent(IslandStyle.self, forKey: .islandStyle)) ?? d.islandStyle
        let storedLive = try? c.decodeIfPresent(Bool.self, forKey: .liveText)
        // old values: "kompakt" -> insel without live text, "live" -> insel with live text
        islandStyle = style == .kapsel ? .kapsel : .insel
        liveText = storedLive ?? (style == .live)
        waveStyle = (try? c.decodeIfPresent(WaveStyle.self, forKey: .waveStyle)) ?? d.waveStyle
        waveLive = (try? c.decodeIfPresent(Bool.self, forKey: .waveLive)) ?? d.waveLive
        alcove = (try? c.decodeIfPresent(AlcoveMode.self, forKey: .alcove)) ?? d.alcove
        confirmSeconds = (try? c.decodeIfPresent(Double.self, forKey: .confirmSeconds)) ?? d.confirmSeconds
        sounds = (try? c.decodeIfPresent(Bool.self, forKey: .sounds)) ?? d.sounds
        hideInFullscreen = (try? c.decodeIfPresent(Bool.self, forKey: .hideInFullscreen)) ?? d.hideInFullscreen
        screenText = (try? c.decodeIfPresent(Bool.self, forKey: .screenText)) ?? d.screenText
        screenTextHistory = (try? c.decodeIfPresent(Bool.self, forKey: .screenTextHistory)) ?? d.screenTextHistory
        keepModelsLoaded = (try? c.decodeIfPresent(Bool.self, forKey: .keepModelsLoaded)) ?? d.keepModelsLoaded
        confirmHoverExpand = (try? c.decodeIfPresent(Bool.self, forKey: .confirmHoverExpand)) ?? d.confirmHoverExpand
        contextLevel = min(3, max(0, (try? c.decodeIfPresent(Int.self, forKey: .contextLevel)) ?? d.contextLevel))
        contextApps = (try? c.decodeIfPresent([String: Int].self, forKey: .contextApps)) ?? d.contextApps
        contextElectron = (try? c.decodeIfPresent(Bool.self, forKey: .contextElectron)) ?? d.contextElectron
        onboardingDone = (try? c.decodeIfPresent(Bool.self, forKey: .onboardingDone)) ?? d.onboardingDone
        muteWhileRecording = (try? c.decodeIfPresent(Bool.self, forKey: .muteWhileRecording)) ?? d.muteWhileRecording
        muteExceptions = (try? c.decodeIfPresent([String].self, forKey: .muteExceptions)) ?? d.muteExceptions
        menuBarStyle = (try? c.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle)) ?? d.menuBarStyle
        uiLanguage = (try? c.decodeIfPresent(UILanguage.self, forKey: .uiLanguage)) ?? (onboardingDone ? .de : d.uiLanguage)
        dictationLanguage = (try? c.decodeIfPresent(DictationLanguage.self, forKey: .dictationLanguage))
            ?? (onboardingDone ? .auto : d.dictationLanguage)
    }

    /// Writes only the SPEC §0 vocabulary: "insel" | "kapsel" plus `liveText`.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(islandStyle == .kapsel ? IslandStyle.kapsel : IslandStyle.insel, forKey: .islandStyle)
        try c.encode(liveText || islandStyle == .live, forKey: .liveText)
        try c.encode(waveStyle, forKey: .waveStyle)
        try c.encode(waveLive, forKey: .waveLive)
        try c.encode(alcove, forKey: .alcove)
        try c.encode(confirmSeconds, forKey: .confirmSeconds)
        try c.encode(sounds, forKey: .sounds)
        try c.encode(hideInFullscreen, forKey: .hideInFullscreen)
        try c.encode(screenText, forKey: .screenText)
        try c.encode(screenTextHistory, forKey: .screenTextHistory)
        try c.encode(keepModelsLoaded, forKey: .keepModelsLoaded)
        try c.encode(confirmHoverExpand, forKey: .confirmHoverExpand)
        try c.encode(contextLevel, forKey: .contextLevel)
        try c.encode(contextApps, forKey: .contextApps)
        try c.encode(contextElectron, forKey: .contextElectron)
        try c.encode(onboardingDone, forKey: .onboardingDone)
        try c.encode(muteWhileRecording, forKey: .muteWhileRecording)
        try c.encode(muteExceptions, forKey: .muteExceptions)
        try c.encode(menuBarStyle, forKey: .menuBarStyle)
        try c.encode(uiLanguage, forKey: .uiLanguage)
        try c.encode(dictationLanguage, forKey: .dictationLanguage)
    }

    static func load() -> UISettings {
        guard let data = try? Data(contentsOf: Paths.settings),
              let s = try? JSONDecoder().decode(UISettings.self, from: data) else { return UISettings() }
        return s
    }

    /// Writes atomically and keeps keys this struct does not know (Python may add some).
    func save() {
        var merged = (try? Data(contentsOf: Paths.settings))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let own = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] {
            merged.merge(own) { _, new in new }
        }
        if let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.settings, options: .atomic)
        }
    }
}

enum Paths {
    /// env VOICEBUD_DATA_DIR overrides the folder (same variable as settings.py; Python's
    /// tests set it and the spawned helper inherits it, so tests never touch real data)
    static let dataDir: URL = {
        let override = ProcessInfo.processInfo.environment["VOICEBUD_DATA_DIR"].map {
            ($0 as NSString).expandingTildeInPath
        }
        let url = override.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/VoiceBud", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var settings: URL { dataDir.appendingPathComponent("settings.json") }
    static var dictionary: URL { dataDir.appendingPathComponent("dictionary.json") }
    static var snippets: URL { dataDir.appendingPathComponent("snippets.json") }
    static var history: URL { dataDir.appendingPathComponent("history.sqlite") }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

enum Palette {
    static let rec = Color(hex: 0xFF453A)
    // dictation violet, prompt teal, command amber
    // dictate violet, prompt teal, command amber, Texterkennung sky blue
    static func accent(_ m: Mode) -> Color {
        Color(hex: [Mode.dictate: 0xB89EFA, .prompt: 0x6BE6D4, .command: 0xFFC56B, .ocr: 0x8CCBFF][m]!)
    }
    static func accentLo(_ m: Mode) -> Color {
        Color(hex: [Mode.dictate: 0x8F6CF2, .prompt: 0x2FBFAA, .command: 0xE89B2E, .ocr: 0x3E92F0][m]!)
    }
    static func accentHi(_ m: Mode) -> Color {
        Color(hex: [Mode.dictate: 0xE4DAFF, .prompt: 0xC8FAF1, .command: 0xFFE7B8, .ocr: 0xDCEEFF][m]!)
    }
}


/// Alcove counts as installed only when it sits in an Applications folder. LaunchServices also
/// knows copies in the Trash, in Downloads, on a mounted disk image or stale entries from an old
/// install, so the bare "is there an app with this bundle id" answer showed Alcove settings on Macs
/// without Alcove.
enum AlcoveProbe {
    static let bundleID = "com.henrikruscon.Alcove"

    static func installed() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).contains { url in
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let inApplications = path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
            return inApplications && !path.contains("/.Trash/") && FileManager.default.fileExists(atPath: path)
        }
    }
}

enum HotkeyFormat {
    /// "ctrl+shift" → "⌃⇧", "alt_r" → "⌥ rechts" ("⌥ right"), "f13" → "F13" (macOS modifier order ⌃⌥⇧⌘).
    static func display(_ spec: String) -> String {
        let order = ["ctrl": 0, "alt": 1, "shift": 2, "cmd": 3]
        let glyph = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘"]
        var parts: [(rank: Int, text: String, sided: Bool)] = []
        for raw in spec.lowercased().split(separator: "+") {
            let name = raw.trimmingCharacters(in: .whitespaces)
            let side = name.hasSuffix("_l") ? " " + L("links") : name.hasSuffix("_r") ? " " + L("rechts") : ""
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
