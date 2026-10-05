// `--render <dir>` (island half): still PNGs of every island state, composited on a
// wallpaper crop of 600×220 pt with a simulated 185×32 notch, at scale 2. Deterministic:
// fixed levels, fixed timer values, fixed shimmer/spinner phase.
import AppKit
import SwiftUI

func renderIslandStates(to dir: URL) throws {
    try MainActor.assumeIsolated {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try IslandRenderer.renderAll(to: dir)
    }
}

@MainActor
enum IslandRenderer {
    enum RenderError: Error { case image(String) }

    nonisolated static let crop = CGSize(width: 600, height: 220)
    static let notch = CGSize(width: 185, height: 32)
    static let speechBands: [Float] = [0.62, 0.85, 0.74, 0.55, 0.42, 0.30, 0.18]
    // the sample texts follow the UI language (05.10.: the README shows the English app)
    private static var en: Bool { Loc.shared.english }
    static var liveSample: String { en
        ? "Hi Ms Becker, thanks for the quick reply. I can't make the meeting on Thursday, no, I mean Friday"
        : "Hallo Frau Becker, vielen Dank für die schnelle Rückmeldung. Den Termin am Donnerstag kann ich leider nicht wahrnehmen, nein, ich meine Freitag" }
    static var liveLong: String { en
        ? "Quick update on the end card: the spacing now matches the series layout from video 1.1, the type is one step smaller and the logo block sits on the baseline again. The only open point is whether the background"
        : "Kurz zum Stand der Endkarte: Die Abstände stimmen jetzt mit dem Serienlayout aus Video 1.1 überein, die Schrift ist eine Stufe kleiner und der Logoblock sitzt wieder auf der Grundlinie. Offen ist nur noch, ob der Hintergrund" }
    static var mailDone: DoneInfo { DoneInfo(app: "Mail", words: 31, seconds: 0.6,
                                   preview: en ? "Hi Ms Becker, thanks for the quick reply about the meeting on Friday."
                                               : "Hallo Frau Becker, vielen Dank für die schnelle Rückmeldung zum Termin am Freitag.",
                                   toClipboard: false) }
    static var liveDone: DoneInfo { DoneInfo(app: "Mail", words: 31, seconds: 0.7,
                                   preview: en ? "Hi Ms Becker,\n\nthanks for the quick reply. Unfortunately I can't make the meeting on Friday. Would Monday at 10 am work for you?\n\nBest regards\nNils"
                                               : "Hallo Frau Becker,\n\nvielen Dank für die schnelle Rückmeldung. Den Termin am Freitag kann ich leider nicht wahrnehmen. Würde Ihnen Montag um 10 Uhr passen?\n\nViele Grüße\nNils",
                                   toClipboard: false) }
    static var clipDone: DoneInfo { DoneInfo(app: "", words: 18, seconds: 0.5,
                                   preview: en ? "Be there in five minutes, go ahead and start without me, the documents are in the team folder."
                                               : "Bin in fünf Minuten da, fangt schon mal ohne mich an, die Unterlagen liegen im Teamordner.",
                                   toClipboard: true) }

    /// hovered confirmations (SPEC §0, 03.10.): a long multi-paragraph mail that needs the fade
    static var longMail: String { en ? """
        Hi Ms Becker,

        thanks for the quick reply and the revised documents. Unfortunately I can't make the meeting on Friday, as I'm with a client in Frankfurt all morning that day.

        Would Monday at 10 am work for you instead? Then we could go through the open points on the end card, the series layout and the schedule for the next three videos in peace. I'll send you a short list beforehand so we're both well prepared.

        If Monday doesn't work, Tuesday afternoon from 2 pm would be fine too. I'll put the rough cut of video 1.4 in our shared folder tonight, the subtitles follow tomorrow morning.

        Best regards
        Nils
        """ : """
        Hallo Frau Becker,

        vielen Dank für die schnelle Rückmeldung und die überarbeiteten Unterlagen. Den Termin am Freitag kann ich leider nicht wahrnehmen, weil ich an dem Tag den ganzen Vormittag beim Kunden in Frankfurt bin.

        Würde Ihnen stattdessen Montag um 10 Uhr passen? Dann könnten wir die offenen Punkte zur Endkarte, zum Serienlayout und zum Zeitplan für die nächsten drei Videos in Ruhe durchgehen. Ich schicke Ihnen vorab eine kurze Liste, damit wir beide gut vorbereitet sind.

        Falls Montag nicht klappt, ginge auch Dienstagnachmittag ab 14 Uhr. Die Rohfassung von Video 1.4 lege ich Ihnen heute Abend in den gemeinsamen Ordner, die Untertitel folgen morgen früh.

        Viele Grüße
        Nils
        """ }
    static var clipText: String { en ? """
        Be there in five minutes, go ahead and start without me. The documents are in the team folder under "General Assembly", the slides are up to date.

        See you soon
        """ : """
        Bin in fünf Minuten da, fangt schon mal ohne mich an. Die Unterlagen liegen im Teamordner unter „Vollversammlung“, die Folien sind auf dem neuesten Stand.

        Bis gleich
        """ }

    static func hoverDone(_ text: String, app: String = "Mail", seconds: Double = 0.7, clipboard: Bool = false,
                     keepLines: Bool = false) -> DoneInfo {
        let words = text.split(whereSeparator: \.isWhitespace).count
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let preview = keepLines
            ? text.replacingOccurrences(of: "\n\n", with: "\n")
            : (flat.count > 80 ? String(flat.prefix(78)) + " …" : flat)
        return DoneInfo(app: app, words: words, seconds: seconds, preview: preview, toClipboard: clipboard,
                        fullText: text)
    }

    nonisolated static let hoverCrop = CGSize(width: 600, height: 380)

    struct Scene {
        let name: String
        var backdrop: IslandBackdrop.Kind = .notch
        var crop: CGSize = IslandRenderer.crop
        let setup: (AppState, IslandModel) -> Void
    }

    static var scenes: [Scene] {
        [
            Scene(name: "kompakt-recording") { s, m in m.phase = .recording; s.phase = .recording },
            Scene(name: "kompakt-processing") { s, m in m.phase = .processing; s.phase = .processing },
            Scene(name: "slow-07s") { s, m in
                m.phase = .processing; s.phase = .processing; m.slowSince = Date(timeIntervalSinceNow: -7)
            },
            Scene(name: "slow-12s") { s, m in
                m.phase = .processing; s.phase = .processing; m.slowSince = Date(timeIntervalSinceNow: -12); m.slowHint = true
            },
            Scene(name: "slow-kapsel-07s") { s, m in
                m.kind = .capsule; m.capsuleTop = 33 + 8; m.phase = .processing; s.phase = .processing
                m.frozenElapsed = 21; m.slowSince = Date(timeIntervalSinceNow: -7)
            },
            Scene(name: "slow-kapsel-12s") { s, m in
                m.kind = .capsule; m.capsuleTop = 33 + 8; m.phase = .processing; s.phase = .processing
                m.frozenElapsed = 21; m.slowSince = Date(timeIntervalSinceNow: -12); m.slowHint = true
            },
            Scene(name: "kompakt-done") { _, m in m.phase = .done; m.done = mailDone },
            Scene(name: "kompakt-clipboard") { _, m in m.phase = .done; m.done = clipDone },
            Scene(name: "kompakt-recording-prompt") { s, m in m.phase = .recording; m.mode = .prompt; s.mode = .prompt },
            Scene(name: "kompakt-error") { _, m in m.phase = .error; m.errorMessage = "Mikrofon nicht verfügbar" },
            Scene(name: "kompakt-nichts-verstanden") { _, m in m.phase = .error; m.errorMessage = "Nichts verstanden" },
            Scene(name: "ocr-bereich-waehlen") { s, m in m.phase = .recording; m.mode = .ocr; s.phase = .recording; s.mode = .ocr },
            Scene(name: "ocr-tabelle-erkannt") { _, m in
                m.phase = .done; m.mode = .ocr
                m.done = DoneInfo(app: "Tabelle erkannt", words: 74, seconds: 0.4,
                                  preview: en ? "Project status October The review of the handover documents is largely …"
                                              : "Projektstand Oktober Die Prüfung der Übergabeunterlagen ist weitgehend …",
                                  toClipboard: true)
            },
            Scene(name: "kompakt-recording-fein") { s, m in m.phase = .recording; s.settings.waveStyle = .fein },
            Scene(name: "kompakt-recording-linie") { s, m in m.phase = .recording; s.settings.waveStyle = .linie },
            Scene(name: "live-recording-start") { s, m in
                m.flavour = .live; m.phase = .recording; m.frozenElapsed = 1; s.partialText = ""
            },
            Scene(name: "live-recording") { s, m in
                m.flavour = .live; m.phase = .recording; m.frozenElapsed = 9; s.partialText = liveSample
            },
            Scene(name: "live-recording-long") { s, m in
                m.flavour = .live; m.phase = .recording; m.frozenElapsed = 21; m.brightWords = 5
                s.partialText = liveLong
            },
            Scene(name: "live-processing") { s, m in
                m.flavour = .live; m.phase = .processing; m.frozenElapsed = 11; s.partialText = liveSample
            },
            Scene(name: "live-done") { _, m in m.flavour = .live; m.phase = .done; m.done = liveDone },
            Scene(name: "capsule-recording") { _, m in
                m.kind = .capsule; m.capsuleTop = 33 + 8; m.phase = .recording; m.frozenElapsed = 4
            },
            Scene(name: "capsule-processing") { _, m in
                m.kind = .capsule; m.capsuleTop = 33 + 8; m.phase = .processing; m.frozenElapsed = 6
            },
            Scene(name: "capsule-done") { _, m in
                m.kind = .capsule; m.capsuleTop = 33 + 8; m.phase = .done; m.done = mailDone
            },
            Scene(name: "capsule-error") { _, m in
                m.kind = .capsule; m.capsuleTop = 33 + 8; m.phase = .error; m.errorMessage = "Mikrofon nicht verfügbar"
            },
            Scene(name: "capsule-live-recording") { s, m in
                m.kind = .capsule; m.flavour = .live; m.capsuleTop = 33 + 8
                m.phase = .recording; m.frozenElapsed = 9; s.partialText = liveSample
            },
            Scene(name: "capsule-live-processing") { s, m in
                m.kind = .capsule; m.flavour = .live; m.capsuleTop = 33 + 8
                m.phase = .processing; m.frozenElapsed = 11; s.partialText = liveSample
            },
            Scene(name: "capsule-live-done") { _, m in
                m.kind = .capsule; m.flavour = .live; m.capsuleTop = 33 + 8; m.phase = .done; m.done = liveDone
            },
            Scene(name: "live-error") { _, m in
                m.flavour = .live; m.phase = .error; m.errorMessage = "Mikrofon nicht verfügbar"
            },
            Scene(name: "capsule-nonotch-recording", backdrop: .noNotchLight) { _, m in
                m.kind = .capsule; m.capsuleTop = 25 + 8; m.phase = .recording; m.frozenElapsed = 4
            },
            Scene(name: "alcove-dodge-recording", backdrop: .alcove) { _, m in
                m.kind = .capsule; m.capsuleTop = notch.height + 8; m.phase = .recording; m.frozenElapsed = 4
            },
            Scene(name: "alcove-dodge-live", backdrop: .alcove) { s, m in
                m.kind = .capsule; m.flavour = .live; m.capsuleTop = notch.height + 8
                m.phase = .recording; m.frozenElapsed = 9; s.partialText = liveSample
            },
            // hovered confirmations: the same card unfolded with the whole text (SPEC §0, 03.10.)
            Scene(name: "kompakt-done-hover", crop: hoverCrop) { _, m in
                m.phase = .done; m.done = hoverDone(longMail); m.hover = .expanded
            },
            Scene(name: "kompakt-done-hover-kontext", crop: hoverCrop) { _, m in
                var d = hoverDone(longMail)
                d.context = ContextInfo(label: "Kontext aus Mail", used: true, app: "Mail", bundle: "com.apple.mail",
                                        rows: [["Text am Cursor", "412 Zeichen"], ["Fenster", "Empfänger und Betreff"],
                                               ["Namen", "Szymańska, Becker"], ["Korrigiert", "Schimanska zu Szymańska"]])
                m.phase = .done; m.done = d; m.hover = .expanded
            },
            Scene(name: "kompakt-done-kontext", crop: hoverCrop) { _, m in
                var d = hoverDone(longMail)
                d.context = ContextInfo(label: "Kontext aus Mail", used: true, app: "Mail", bundle: "com.apple.mail",
                                        rows: [["Text am Cursor", "412 Zeichen"]])
                m.phase = .done; m.done = d
            },
            Scene(name: "kompakt-done-hover-kopiert", crop: hoverCrop) { _, m in
                m.phase = .done; m.done = hoverDone(longMail); m.hover = .expanded; m.stillCopied = true
            },
            Scene(name: "kompakt-clipboard-hover", crop: hoverCrop) { _, m in
                m.phase = .done; m.done = hoverDone(clipText, app: "", seconds: 0.5, clipboard: true); m.hover = .expanded
            },
            Scene(name: "live-done-hover", crop: hoverCrop) { _, m in
                m.flavour = .live; m.phase = .done; m.done = hoverDone(longMail, keepLines: true); m.hover = .expanded
            },
            Scene(name: "capsule-done-hover", crop: hoverCrop) { _, m in
                m.kind = .capsule; m.capsuleTop = 33 + 8; m.phase = .done; m.done = hoverDone(longMail)
                m.hover = .expanded
            },
            Scene(name: "capsule-clipboard-hover", crop: hoverCrop) { _, m in
                m.kind = .capsule; m.capsuleTop = 33 + 8; m.phase = .done; m.mode = .prompt
                m.done = hoverDone(clipText, app: "", seconds: 0.5, clipboard: true); m.hover = .expanded
            },
            Scene(name: "capsule-live-done-hover", crop: hoverCrop) { _, m in
                m.kind = .capsule; m.flavour = .live; m.capsuleTop = 33 + 8; m.phase = .done
                m.done = hoverDone(longMail, keepLines: true); m.hover = .expanded
            },
        ]
    }

    static func renderAll(to dir: URL) throws {
        for scene in scenes {
            let state = AppState()
            state.settings = UISettings()
            state.settings.waveStyle = .sym
            state.settings.waveLive = true
            state.phase = .recording
            state.bands = speechBands
            let model = IslandModel()
            model.notch = notch
            model.canvas = scene.crop
            model.presented = true
            model.stillTime = 0.75
            model.reduceMotion = false
            scene.setup(state, model)
            if model.phase != .recording { state.bands = Array(repeating: 0, count: 7) }
            let view = ZStack(alignment: .top) {
                IslandBackdrop(kind: scene.backdrop, notch: notch)
                IslandView(state: state, model: model)
            }
            .frame(width: scene.crop.width, height: scene.crop.height)
            try write(view, to: dir.appendingPathComponent("island-\(scene.name).png"), scale: 2)
        }
        try write(WaveSheet(), to: dir.appendingPathComponent("island-waves.png"), scale: 8)
    }

    static func write<V: View>(_ view: V, to url: URL, scale: CGFloat) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw RenderError.image(url.lastPathComponent)
        }
        try data.write(to: url)
    }
}

/// Top-centre crop of a 14" MacBook Pro: wallpaper, menu bar, hardware notch (and, for the
/// Alcove scenes, Alcove's own island showing a music activity).
struct IslandBackdrop: View {
    enum Kind { case notch, alcove, noNotchLight }
    let kind: Kind
    let notch: CGSize

    var body: some View {
        ZStack(alignment: .top) {
            if kind == .noNotchLight {
                RadialGradient(stops: [.init(color: Color(hex: 0xFBE3D2), location: 0),
                                       .init(color: Color(hex: 0xEFBFAE), location: 0.38),
                                       .init(color: Color(hex: 0xC497B6), location: 1)],
                               center: UnitPoint(x: 0.75, y: 0), startRadius: 0, endRadius: 560)
                Rectangle().fill(Color.white.opacity(0.22)).frame(height: 25)
            } else {
                RadialGradient(stops: [.init(color: Color(hex: 0x5A4BB0), location: 0),
                                       .init(color: Color(hex: 0x2C2470), location: 0.42),
                                       .init(color: Color(hex: 0x130F33), location: 1)],
                               center: UnitPoint(x: 0.18, y: 0), startRadius: 0, endRadius: 600)
                Rectangle().fill(Color(hex: 0x120E2E, opacity: 0.16)).frame(height: notch.height + 1)
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                    .fill(Color.black)
                    .frame(width: notch.width, height: notch.height)
            }
            if kind == .alcove { alcoveMusic }
        }
    }

    /// stand-in for Alcove's live activity (album art left, pink level bars right)
    private var alcoveMusic: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xF6A5C0), Color(hex: 0x7B5CFF)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 20, height: 20)
                .padding(.leading, 14)
            Spacer()
            HStack(spacing: 1.5) {
                ForEach(Array([7.0, 11.0, 5.0, 9.0].enumerated()), id: \.offset) { _, h in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(LinearGradient(colors: [Color(hex: 0xE879A8), Color(hex: 0xFDE2EE)],
                                             startPoint: .bottom, endPoint: .top))
                        .frame(width: 2, height: h)
                }
            }
            .padding(.trailing, 14)
        }
        .frame(width: 300, height: notch.height)
        .background(alignment: .top) {
            NotchShape(topRadius: 8, bottomRadius: 12).fill(Color.black).padding(.horizontal, -8)
        }
    }
}

/// Close-up of the three waveform styles (scale 8): live speech in both modes, silence,
/// and the calm synthetic animation.
private struct WaveSheet: View {
    var body: some View {
        let rows: [(String, Mode, Bool, [Float])] = [
            ("Live, Diktat", .dictate, true, IslandRenderer.speechBands),
            ("Live, Prompt", .prompt, true, IslandRenderer.speechBands),
            ("Stille", .dictate, true, Array(repeating: 0, count: 7)),
            ("Synthetisch", .dictate, false, Array(repeating: 0, count: 7)),
        ]
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(row.0)
                        .font(.system(size: 6, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 44, alignment: .leading)
                    ForEach(WaveStyle.allCases, id: \.self) { style in
                        WaveformView(style: style, mode: row.1, live: row.2, levels: { row.3 }, still: 0.75)
                            .frame(width: 40, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black))
                    }
                }
            }
        }
        .padding(10)
        .background(Color(hex: 0x1A1730))
    }
}
