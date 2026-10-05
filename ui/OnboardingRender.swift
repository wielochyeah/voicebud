// `--render-onboarding <dir>`: PNGs (scale 2) of every onboarding step, drawn headless with
// ImageRenderer from mock state, plus a contact sheet with all of them. Light mode for every step,
// dark for 1, 2, 3 and 10, and the extra states (dialog open, denied, granted, restart, offline,
// listening, silent microphone, capsule).
import AppKit
import SwiftUI

func renderOnboarding(to dir: URL) throws {
    try MainActor.assumeIsolated { try OnboardingRenderer.renderAll(to: dir) }
}

@MainActor
enum OnboardingRenderer {
    typealias Step = OnboardingModel.Step

    enum RenderError: Error, CustomStringConvertible {
        case image(String)
        var description: String {
            switch self { case .image(let n): return "ImageRenderer produced no image for \(n)" }
        }
    }

    struct Shot {
        let file: String
        let label: String
        let step: Step
        var dark = false
        var setup: (OnboardingModel) -> Void = { _ in }
    }

    static let testText = OnboardingModel.sampleTake

    /// file number = position in the full flow (with Alcove), so names stay stable
    static func number(_ s: Step) -> String { String(format: "%02d", s.rawValue + 1) }

    static func label(_ s: Step, _ extra: String = "") -> String {
        "\(s.rawValue + 1) \(s.title)" + (extra.isEmpty ? "" : ", \(extra)")
    }

    static var shots: [Shot] {
        var out: [Shot] = Step.allCases.map { step in
            Shot(file: "\(number(step))-\(slug(step))-light",
                 label: step == .alcove ? label(step, "nur wenn Alcove läuft") : label(step), step: step)
        }
        out += [
            Shot(file: "\(number(.welcome))b-willkommen-aufnahme-light", label: label(.welcome, "Insel nimmt auf"), step: .welcome) {
                $0.stillHero = .recording
            },
            Shot(file: "\(number(.microphone))b-mikrofon-wartet-light", label: label(.microphone, "Dialog offen"), step: .microphone) {
                $0.grants[.microphone] = .requested
            },
            Shot(file: "\(number(.microphone))c-mikrofon-abgelehnt-light", label: label(.microphone, "abgelehnt"), step: .microphone) {
                $0.grants[.microphone] = .denied
            },
            Shot(file: "\(number(.microphone))d-mikrofon-erteilt-light", label: label(.microphone, "erteilt"), step: .microphone) {
                $0.grants[.microphone] = .granted
            },
            Shot(file: "\(number(.accessibility))b-bedienungshilfen-wartet-light", label: label(.accessibility, "wartet auf den Schalter"),
                 step: .accessibility) {
                $0.grants[.accessibility] = .requested
            },
            Shot(file: "\(number(.accessibility))c-bedienungshilfen-erteilt-light", label: label(.accessibility, "erteilt"), step: .accessibility) {
                $0.grants[.accessibility] = .granted
            },
            Shot(file: "\(number(.inputMonitoring))b-eingabe-neustart-light", label: label(.inputMonitoring, "erteilt, Neustart"),
                 step: .inputMonitoring) {
                $0.grants[.inputMonitoring] = .granted
                $0.restartNeeded = true
            },
            Shot(file: "\(number(.inputMonitoring))c-eingabe-erteilt-light", label: label(.inputMonitoring, "nach dem Neustart"),
                 step: .inputMonitoring) {
                $0.grants[.inputMonitoring] = .granted
            },
            Shot(file: "\(number(.models))b-modelle-offline-light", label: label(.models, "offline"), step: .models) {
                $0.models[1].phase = .paused(receivedMB: 1120, totalMB: 2500)
            },
            Shot(file: "\(number(.testDictation))b-probediktat-hoert-zu-light", label: label(.testDictation, "hört zu"), step: .testDictation) {
                $0.test = .listening
            },
            Shot(file: "\(number(.testDictation))c-probediktat-wartet-light", label: label(.testDictation, "wartet"), step: .testDictation) {
                $0.test = .ready
            },
            Shot(file: "\(number(.testDictation))d-probediktat-flach-light", label: label(.testDictation, "kein Ton nach 3 s"),
                 step: .testDictation) {
                $0.test = .listening
                $0.flatSignal = true
            },
            Shot(file: "\(number(.appearance))b-darstellung-kapsel-light", label: label(.appearance, "Kapsel"), step: .appearance) {
                $0.islandShape = .kapsel
            },
            Shot(file: "\(number(.screenText))b-texterkennung-gefragt-light", label: label(.screenText, "Dialog gezeigt"), step: .screenText) {
                $0.screenTextPreview = false
                $0.screenTextAsked = true
            },
            Shot(file: "\(number(.screenText))c-texterkennung-erteilt-light", label: label(.screenText, "erteilt"), step: .screenText) {
                $0.screenTextPreview = true
            },
            Shot(file: "\(number(.welcome))-willkommen-dark", label: label(.welcome, "dunkel"), step: .welcome, dark: true),
            Shot(file: "\(number(.howItWorks))-so-funktionierts-dark", label: label(.howItWorks, "dunkel"), step: .howItWorks, dark: true),
            Shot(file: "\(number(.microphone))-mikrofon-dark", label: label(.microphone, "dunkel"), step: .microphone, dark: true),
            Shot(file: "\(number(.context))-mitlesen-dark", label: label(.context, "dunkel"), step: .context, dark: true),
        ]
        return out
    }

    static func slug(_ s: Step) -> String {
        switch s {
        case .language: return "sprache"
        case .welcome: return "willkommen"
        case .howItWorks: return "so-funktionierts"
        case .microphone: return "mikrofon"
        case .accessibility: return "bedienungshilfen"
        case .inputMonitoring: return "eingabeueberwachung"
        case .models: return "modelle"
        case .testDictation: return "probediktat"
        case .appearance: return "darstellung"
        case .alcove: return "alcove"
        case .context: return "mitlesen"
        case .screenText: return "texterkennung"
        case .finish: return "fertig"
        }
    }

    static func makeModel(_ shot: Shot) -> OnboardingModel {
        let m = OnboardingModel()
        m.rendering = true
        m.mock = true
        m.alcoveInstalled = true
        m.test = .result(text: testText, seconds: 0.4)
        m.receiveLevels(OnboardingLevelBars.still)
        m.step = shot.step
        m.screenTextPreview = false            // the first look; the variants set their own
        shot.setup(m)
        return m
    }

    static func renderAll(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cells: [(label: String, url: URL)] = []
        for shot in shots {
            let scheme: ColorScheme = shot.dark ? .dark : .light
            let model = makeModel(shot)
            let view = OnboardingBoard(scheme: scheme) { OnboardingStaticWindow(model: model) }
                .environment(\.colorScheme, scheme)
                .environment(\.hubStatic, true)
            let url = dir.appendingPathComponent("onboarding-\(shot.file).png")
            try write(view, to: url, scale: 2)
            cells.append((shot.label, url))
        }
        // sheet order: each step in light, then its states, then its dark render
        func key(_ url: URL) -> String {
            let name = url.lastPathComponent.replacingOccurrences(of: "onboarding-", with: "")
            return String(name.prefix(2)) + (name.contains("-dark") ? "~" : "") + name
        }
        let order = cells.sorted { key($0.url) < key($1.url) }
        let sheet = OnboardingContactSheet(cells: order.map { ($0.label, NSImage(contentsOf: $0.url)) })
        try write(sheet, to: dir.appendingPathComponent("onboarding-contact-sheet.png"), scale: 1.5)
    }

    static func write<V: View>(_ view: V, to url: URL, scale: CGFloat) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = false
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { throw RenderError.image(url.lastPathComponent) }
        try png.write(to: url, options: .atomic)
    }
}

/// Neutral desk around the window (same as the hub renders).
struct OnboardingBoard<Content: View>: View {
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

/// All renders in a grid, four per row, each labelled with its step.
struct OnboardingContactSheet: View {
    let cells: [(String, NSImage?)]
    private let cellWidth: CGFloat = 400
    private let columns = 4

    var body: some View {
        let rows = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 4) {
                Text("VoiceBud Onboarding").font(.system(size: 22, weight: .bold))
                Text("11 Schritte mit Alcove, 10 ohne, 720 × 560 pt, dazu Zustände und Dunkelmodus")
                    .font(.system(size: 13)).foregroundStyle(Color(hex: 0x3C3C43, opacity: 0.64))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 22) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        VStack(alignment: .leading, spacing: 8) {
                            Group {
                                if let image = cell.1 {
                                    Image(nsImage: image).resizable().interpolation(.high)
                                        .aspectRatio(contentMode: .fit)
                                } else {
                                    Color.gray.opacity(0.2)
                                }
                            }
                            .frame(width: cellWidth)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(cell.0)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x1D1D1F))
                                .padding(.leading, 2)
                        }
                    }
                }
            }
        }
        .padding(36)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
