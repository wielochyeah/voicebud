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
        Shot(name: "allgemein", pane: .allgemein),
    ]

    static func renderAll(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for shot in shots {
            for scheme in [ColorScheme.light, .dark] {
                let model = makeModel(shot)
                let view = HubRenderBoard(scheme: scheme) { HubStaticWindow(model: model) }
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
