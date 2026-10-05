// Island UI (SPEC §0, §4): NotchShape, IslandView (notch island, compact or with live text),
// CapsuleView (pill + hanging live card), WaveformView and the small state glyphs. Pure
// SwiftUI; the panel, screen geometry and timing live in IslandWindow.swift, stills in
// IslandRender.swift.
//
// Motion follows SPEC §0 (Alcove's own values): every surface is ONE black shape whose width
// and height(+radii) animate with their own interpolating springs, content enters/leaves/swaps
// with the §0 transitions. Stills and Reduce Motion use a plain layout path (shape sized by its
// content, no morphing) so renders are exact and Reduce Motion only cross-fades.
import AppKit
import SwiftUI

// MARK: - Presentation model

/// What the island shows right now. Owned by IslandController (and built directly by the
/// renderer). It deliberately lags AppState: a done card keeps showing while Python already
/// sent `idle`, and the shape/position is decided once per take at recording start.
@Observable
final class IslandModel {
    enum Kind: Equatable { case notch, capsule }
    enum Flavour: Equatable { case compact, live }
    /// SPEC §0 (03.10.): the pointer on a done card. `none`: not hovered yet; `expanded`: the
    /// same card unfolded with the whole text; `collapsed`: folded back after the pointer left
    /// (that change runs on the collapse springs)
    enum Hover: Equatable { case none, expanded, collapsed }

    var kind: Kind = .notch
    var flavour: Flavour = .compact
    /// false = shrunk back into the hardware notch / the capsule's tiny pill (panel orders out next)
    var presented = false
    var phase: Phase = .idle
    var mode: Mode = .dictate
    /// measured per take (never hard-coded); 185×32 only as a fallback
    var notch = CGSize(width: 185, height: 32)
    var canvas = IslandMetrics.canvas
    /// distance from the screen top to the capsule (below menu bar, or below the notch for Alcove)
    var capsuleTop: CGFloat = 41
    var recordingStart = Date()
    /// set when recording ends; the timer then stands still
    var frozenElapsed: TimeInterval?
    var done: DoneInfo?
    var errorMessage: String?
    var noticeOK = false
    /// how many trailing words of the live text are bright (the rest is dimmed)
    var brightWords = 6
    var reduceMotion = false
    /// non-nil → deterministic still (renderer): no timelines, no smoothing, fixed phases
    var stillTime: Double?
    /// processing has taken 5 s or more: when it started (the ear counts the seconds)
    var slowSince: Date?
    /// processing has taken 10 s or more: the card says "Dauert länger" and how to cancel
    var slowHint = false
    /// false while a surface grows out of the notch / pill or shrinks back (glyphs enter and
    /// leave with the §0 blur/scaleX transition); true while it stays on screen and only its
    /// content changes (glyphs swap with the 150/14 spring)
    var contentSwap = false
    var hover: Hover = .none
    /// The visible surface's (animated) body rect in canvas points, top-left origin, reported by
    /// the views for the controller's pointer polling. Not observed: writing it never re-renders.
    @ObservationIgnored var cardFrame: CGRect = .zero
    /// renderer only: the copy button shows its "Kopiert" feedback
    var stillCopied = false

    /// The words that arrived with the latest `partial` stay bright (3…12), older ones dim.
    func noteLiveText(old: String, new: String) {
        let o = old.split(whereSeparator: \.isWhitespace)
        let n = new.split(whereSeparator: \.isWhitespace)
        var common = 0
        while common < o.count, common < n.count, o[common] == n[common] { common += 1 }
        brightWords = min(max(n.count - common, 3), 12)
    }
}

extension UISettings {
    /// SPEC §0 shape choice: everything that is not "kapsel" is the island at the notch.
    var islandShape: IslandStyle { islandStyle == .kapsel ? .kapsel : .insel }
}

// MARK: - Metrics and motion

enum IslandMetrics {
    /// tall enough for a hovered confirmation (capsule below the menu bar + 12 text lines +
    /// the copy row + its shadow); the panel is transparent and click-through everywhere else
    static let canvas = CGSize(width: 640, height: 400)
    /// compact island: each ear adds this much to the notch width
    static let earWidth: CGFloat = 50
    static let earPad: CGFloat = 14
    static let doneWidth: CGFloat = 400
    static let liveWidth: CGFloat = 470
    /// body text starts flush with the badge column of the ear row above it
    static let bodyPad: CGFloat = 14
    static let capsuleHeight: CGFloat = 40
    /// the capsule grows out of (and shrinks back into) this tiny pill at its anchor
    static let seed = CGSize(width: 36, height: 8)
    /// gap between the capsule and the live card hanging below it
    static let cardGap: CGFloat = 6
    static let liveFontSize: CGFloat = 13.5
    static let liveLineSpacing: CGFloat = 3
    static let liveMaxLines = 3
    static let waveHeight: CGFloat = 14
    static let errorFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    /// hovered confirmation (SPEC §0): the same card, widened to this and as tall as the text
    static let hoverWidth: CGFloat = 470
    static let fullTextMaxLines = 12
    static let fullTextParagraphGap: CGFloat = 6
}

/// SPEC §0: Alcove's springs (framer-motion, mass 1) as interpolating springs.
enum IslandMotion {
    /// width: grow out of the notch, widen for a card
    static let widthGrow = Animation.interpolatingSpring(mass: 1, stiffness: 150, damping: 20)
    static let widthCollapse = Animation.interpolatingSpring(mass: 1, stiffness: 200, damping: 20)
    /// height + bottom radius + ear radius: drop-down, live text growing
    static let heightGrow = Animation.interpolatingSpring(mass: 1, stiffness: 250, damping: 21)
    static let heightCollapse = Animation.interpolatingSpring(mass: 1, stiffness: 250, damping: 25)
    /// content swap inside a surface (waveform → spinner → check)
    static let swap = Animation.interpolatingSpring(mass: 1, stiffness: 150, damping: 14)
    /// Reduce Motion: cross-fades only
    static let crossFade = Animation.easeInOut(duration: 0.2)

    static func width(growing: Bool) -> Animation { growing ? widthGrow : widthCollapse }
    static func height(growing: Bool) -> Animation { growing ? heightGrow : heightCollapse }
}

/// Content entering: blur 10, scaleX 0.75 from the notch side, opacity 0 → identity (0.30 s
/// ease-out). Leaving: blur 4, scaleX 0.25, opacity 0 (0.25 s ease-in).
private struct IslandBlurScaleFX: ViewModifier {
    var blur: CGFloat
    var scaleX: CGFloat
    var opacity: Double
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(x: scaleX, y: 1, anchor: anchor)
            .opacity(opacity)
    }
}

/// Content swap: scale 0.8, a small y offset, blur(height / 6), opacity 0 → identity.
private struct IslandSwapFX: ViewModifier {
    var scale: CGFloat
    var y: CGFloat
    var blur: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(scale)
            .offset(y: y)
            .opacity(opacity)
    }
}

extension AnyTransition {
    /// SPEC §0 content entering / leaving a surface, anchored towards the notch (or the pill).
    static func islandEnter(toward anchor: UnitPoint, reduce: Bool) -> AnyTransition {
        if reduce { return AnyTransition.opacity.animation(IslandMotion.crossFade) }
        let rest = IslandBlurScaleFX(blur: 0, scaleX: 1, opacity: 1, anchor: anchor)
        return .asymmetric(
            insertion: AnyTransition.modifier(
                active: IslandBlurScaleFX(blur: 10, scaleX: 0.75, opacity: 0, anchor: anchor), identity: rest)
                .animation(.easeOut(duration: 0.30)),
            removal: AnyTransition.modifier(
                active: IslandBlurScaleFX(blur: 4, scaleX: 0.25, opacity: 0, anchor: anchor), identity: rest)
                .animation(.easeIn(duration: 0.25)))
    }

    /// SPEC §0 content swap inside a surface that stays on screen.
    static func islandSwap(height: CGFloat = 32, reduce: Bool) -> AnyTransition {
        if reduce { return AnyTransition.opacity.animation(IslandMotion.crossFade) }
        return AnyTransition.modifier(
            active: IslandSwapFX(scale: 0.8, y: 4, blur: height / 6, opacity: 0),
            identity: IslandSwapFX(scale: 1, y: 0, blur: 0, opacity: 1))
            .animation(IslandMotion.swap)
    }

    /// glyphs in an ear or the pill: swap while the surface stays, enter/leave with the surface
    static func islandGlyph(swap: Bool, toward anchor: UnitPoint, reduce: Bool) -> AnyTransition {
        swap ? .islandSwap(reduce: reduce) : .islandEnter(toward: anchor, reduce: reduce)
    }

    /// Preview ↔ whole text on a hovered confirmation: both start with the same words at the
    /// same place, so the outgoing block hands over with a quick fade (instead of squeezing
    /// across the incoming lines) and the incoming one enters with the §0 enter transition,
    /// 50 ms later, when the outgoing lines are nearly gone.
    static func islandHandOver(reduce: Bool) -> AnyTransition {
        if reduce { return AnyTransition.opacity.animation(IslandMotion.crossFade) }
        return .asymmetric(
            insertion: AnyTransition.modifier(
                active: IslandBlurScaleFX(blur: 10, scaleX: 0.75, opacity: 0, anchor: .top),
                identity: IslandBlurScaleFX(blur: 0, scaleX: 1, opacity: 1, anchor: .top))
                .animation(.easeOut(duration: 0.30).delay(0.05)),
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.12)))
    }
}

/// Animation key for content changes inside a surface (makes the transaction animated, so the
/// transitions above run; they carry their own timing).
struct IslandContentKey: Equatable {
    let phase: Phase
    let presented: Bool
    let flavour: IslandModel.Flavour
    var slow = 0          // 1 = counting (5 s), 2 = "Dauert länger" (10 s): their glyphs swap in too
}

// MARK: - Copy

enum IslandCopy {
    /// "0,7 s" in German, "0.7 s" in English
    static func seconds(_ s: Double) -> String {
        let value = String(format: "%.1f", max(0, s))
        return (Loc.shared.english ? value : value.replacingOccurrences(of: ".", with: ",")) + " s"
    }

    static func words(_ n: Int) -> String { n == 1 ? L("1 Wort") : L("%d Wörter", n) }

    static func title(_ d: DoneInfo, mode: Mode) -> String {
        if mode == .ocr { return d.app.isEmpty ? L("Text erkannt") : message(d.app) }   // "Tabelle erkannt"
        if d.toClipboard { return mode == .prompt ? L("Prompt in der Zwischenablage") : L("In der Zwischenablage") }
        let app = d.app.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .command { return app.isEmpty ? L("Überarbeitet") : L("Überarbeitet in %@", app) }
        return app.isEmpty ? L("Eingefügt") : L("Eingefügt in %@", app)
    }

    /// dim suffix after the title; seconds move here when the right slot holds ⌘V.
    /// Items are separated by a plain gap (en + thin space), never a middle dot (SPEC §0).
    static func meta(_ d: DoneInfo) -> String {
        var parts: [String] = []
        if d.words > 0 { parts.append(words(d.words)) }
        if d.toClipboard && d.seconds > 0 { parts.append(seconds(d.seconds)) }
        if let c = d.context, c.used, !c.rows.isEmpty { parts.append(L("mit Kontext")) }
        if let c = d.context, c.noteworthy { parts.append(contextLabel(c.label, inline: true)) }
        let gap = "\u{2002}\u{2009}"
        return parts.isEmpty ? "" : gap + parts.joined(separator: gap)
    }

    // MARK: texts of the core

    /// A message of the Python core or of Texterkennung (error and notice cards, the table count
    /// of a recognition) in the current language. Both send German, which stays the protocol value
    /// (state, logs and traces keep it); it is translated here, where it is shown. Fixed messages
    /// are looked up as they are, the few the core builds from parts are taken apart first.
    static func message(_ m: String) -> String {
        guard Loc.shared.english else { return m }
        if let fixed = Loc.en[m] { return fixed }
        if let rest = m.dropPrefix("Gelernt: ") {
            if let r = rest.range(of: " wird ") {
                return L("Gelernt: %@ wird %@", String(rest[..<r.lowerBound]), String(rest[r.upperBound...]))
            }
            return L("Gelernt: %@", rest)
        }
        if let reason = m.dropPrefix("Befehl: ") { return L("Befehl: %@", withheld(reason)) }
        if let type = m.dropPrefix("Fehler: ") { return L("Fehler: %@", type) }
        if let n = m.dropSuffix(" Tabellen erkannt").flatMap({ Int($0) }) { return L("%d Tabellen erkannt", n) }
        return probe(m) ?? m
    }

    /// why the core held the screen context back (context.py _LABELS)
    static func withheld(_ reason: String) -> String { Loc.en[reason] ?? reason }

    /// Kontext-Probe (menu, hold ⌥): "Mail: Cursor 412 Zeichen, Dokument 1.200, Fenster 3.400" or
    /// "Mail: Passwortfeld". nil when a part is not one of these.
    private static func probe(_ m: String) -> String? {
        guard let colon = m.range(of: ": ", options: .backwards) else { return nil }
        var parts: [String] = []
        for part in m[colon.upperBound...].components(separatedBy: ", ") {
            if let n = part.dropPrefix("Cursor ")?.dropSuffix(" Zeichen") {
                parts.append(L("Cursor %@ Zeichen", number(n)))
            } else if let n = part.dropPrefix("Dokument ") {
                parts.append(L("Dokument %@", number(n)))
            } else if let n = part.dropPrefix("Fenster ") {
                parts.append(L("Fenster %@", number(n)))
            } else if let label = Loc.en[part] {
                parts.append(label)
            } else {
                return nil
            }
        }
        return String(m[..<colon.upperBound]) + parts.joined(separator: ", ")
    }

    /// "1.234" (as the core writes counts) -> "1,234"
    static func number(_ s: String) -> String {
        guard Loc.shared.english, s.allSatisfy({ $0.isNumber || $0 == "." }) else { return s }
        return s.replacingOccurrences(of: ".", with: ",")
    }

    /// The context label of a take: "Kontext aus Mail", "Ohne Kontext, Passwortfeld". `inline`:
    /// inside the dim meta after the title, where "ohne" starts lower case.
    static func contextLabel(_ label: String, inline: Bool = false) -> String {
        guard Loc.shared.english else {
            return inline ? label.replacingOccurrences(of: "Ohne Kontext, ", with: "ohne Kontext, ") : label
        }
        if let reason = label.dropPrefix("Ohne Kontext, ") {
            return inline ? L("ohne Kontext, %@", withheld(reason)) : L("Ohne Kontext, %@", withheld(reason))
        }
        if let app = label.dropPrefix("Kontext aus ") { return L("Kontext aus %@", app) }
        return Loc.en[label] ?? label
    }

    /// A row of the context section: the core's fixed labels, counts ("412 Zeichen"), names (kept as
    /// they are), fixes ("Schimanska zu Szymańska"), the register and the prompt's material.
    static func contextRow(_ row: [String]) -> (label: String, value: String) {
        let label = row.first ?? "", value = row.count > 1 ? row[1] : ""
        guard Loc.shared.english else { return (label, value) }
        let shown: String
        if let n = value.dropSuffix(" Zeichen"), n.allSatisfy({ $0.isNumber || $0 == "." }) {
            shown = L("%@ Zeichen", number(n))
        } else if label == "Korrigiert" {
            shown = value.components(separatedBy: ", ").map { fix in
                guard let r = fix.range(of: " zu ") else { return fix }
                return L("%@ zu %@", String(fix[..<r.lowerBound]), String(fix[r.upperBound...]))
            }.joined(separator: ", ")
        } else if label == "Im Prompt", let r = materialSource(value) {
            // "Markierter Text aus Mail („Betreff“)": German quotes „…“ become English “…”
            let source = String(value[..<r.lowerBound])
            let rest = String(value[r.upperBound...]).replacingOccurrences(of: "“", with: "”")
                .replacingOccurrences(of: "„", with: "“")
            shown = L("%@ aus %@", Loc.en[source] ?? source, rest)
        } else if label == "Namen" {
            shown = value
        } else {
            shown = Loc.en[value] ?? value
        }
        return (Loc.en[label] ?? label, shown)
    }

    /// the " aus " after the material's source ("Text aus dem Eingabefeld aus Mail" has two):
    /// the first one whose source has a translation
    private static func materialSource(_ value: String) -> Range<String.Index>? {
        var cut = value.range(of: " aus ")
        while let c = cut, Loc.en[String(value[..<c.lowerBound])] == nil {
            cut = value.range(of: " aus ", range: c.upperBound..<value.endIndex)
        }
        return cut
    }

    /// One line for the compact card. The live card keeps the text's own line structure
    /// (greeting, paragraphs, sign-off on their own lines; blank lines collapse into one break).
    static func preview(_ d: DoneInfo, keepLines: Bool = false) -> String {
        let p = d.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty, d.toClipboard { return L("Kein Textfeld aktiv. Mit ⌘V überall einfügen.") }
        if keepLines {
            return p.replacingOccurrences(of: "[ \\t]*\\n[ \\t\\n]*", with: "\n", options: .regularExpression)
        }
        return p.replacingOccurrences(of: "\n", with: " ")
    }

    /// The whole final text for a hovered confirmation as paragraphs: blank lines separate them
    /// (drawn as a small gap), single breaks stay inside a paragraph (greeting, sign-off).
    static func paragraphs(_ d: DoneInfo) -> [String] {
        let text = d.fullText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var paragraphs: [[String]] = [[]]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !(paragraphs.last ?? []).isEmpty { paragraphs.append([]) }
            } else {
                paragraphs[paragraphs.count - 1].append(line)
            }
        }
        let out = paragraphs.filter { !$0.isEmpty }.map { $0.joined(separator: "\n") }
        return out.isEmpty ? [preview(d, keepLines: true)] : out
    }

    static func timer(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func messageWidth(_ message: String) -> CGFloat {
        ceil((message as NSString).size(withAttributes: [.font: IslandMetrics.errorFont]).width)
    }

    /// notch error card: as narrow as the compact island, wider only when the message needs it
    static func notchErrorWidth(_ message: String, notch: CGFloat) -> CGFloat {
        min(IslandMetrics.doneWidth,
            max(notch + 2 * IslandMetrics.earWidth, messageWidth(message) + 2 * IslandMetrics.bodyPad))
    }

    /// capsule error card: badge 20 + gap 8 + message, paddings 10 / 16
    static func capsuleErrorWidth(_ message: String) -> CGFloat {
        min(IslandMetrics.doneWidth, max(160, messageWidth(message) + 10 + 20 + 8 + 16))
    }
}

private extension String {
    /// the rest after `prefix`, nil when the text does not start with it
    func dropPrefix(_ prefix: String) -> String? { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil }
    /// the text before `suffix`, nil when it does not end with it
    func dropSuffix(_ suffix: String) -> String? { hasSuffix(suffix) ? String(dropLast(suffix.count)) : nil }
}

// MARK: - Shapes

/// The hardware notch extended in pure black: flat top flush with the screen edge, concave
/// "ears" (radius `topRadius`) flowing into the menu bar, rounded bottom corners. The rect
/// includes the ears, i.e. the black body is `width - 2 * topRadius` wide.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let tr = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let left = rect.minX + tr, right = rect.maxX - tr
        let br = max(0, min(bottomRadius, (right - left) / 2, rect.height - tr))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        if tr > 0 {
            p.addArc(tangent1End: CGPoint(x: right, y: rect.minY),
                     tangent2End: CGPoint(x: right, y: rect.minY + tr), radius: tr)
        }
        p.addLine(to: CGPoint(x: right, y: rect.maxY - br))
        if br > 0 {
            p.addArc(tangent1End: CGPoint(x: right, y: rect.maxY),
                     tangent2End: CGPoint(x: right - br, y: rect.maxY), radius: br)
        }
        p.addLine(to: CGPoint(x: left + br, y: rect.maxY))
        if br > 0 {
            p.addArc(tangent1End: CGPoint(x: left, y: rect.maxY),
                     tangent2End: CGPoint(x: left, y: rect.maxY - br), radius: br)
        }
        p.addLine(to: CGPoint(x: left, y: rect.minY + tr))
        if tr > 0 {
            p.addArc(tangent1End: CGPoint(x: left, y: rect.minY),
                     tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: tr)
        }
        p.closeSubpath()
        return p
    }
}

private struct IslandCheckGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 5 / 24, y: r.minY + r.height * 12.5 / 24))
        p.addLine(to: CGPoint(x: r.minX + r.width * 9.5 / 24, y: r.minY + r.height * 17 / 24))
        p.addLine(to: CGPoint(x: r.minX + r.width * 19 / 24, y: r.minY + r.height * 7.5 / 24))
        return p
    }
}

// MARK: - Morphing surface

/// Animated geometry of one black surface: width, height and corner radii. `top` is the
/// notch's concave ear radius (unused by capsules), `bottom` the bottom corner radius (the
/// capsule's corner radius).
struct IslandSurfaceGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    var top: CGFloat = 0
    var bottom: CGFloat
}

private struct IslandSurfaceKey: EnvironmentKey {
    static let defaultValue = IslandSurfaceGeometry(width: 0, height: 0, top: 0, bottom: 0)
}

extension EnvironmentValues {
    /// the current (animated) geometry of the surface a view sits in
    var islandSurface: IslandSurfaceGeometry {
        get { self[IslandSurfaceKey.self] }
        set { self[IslandSurfaceKey.self] = newValue }
    }
}

/// Width and height(+radii) live in two Animatable modifiers, each wrapped in its own
/// value-scoped animation, so they spring independently even when both change in the same
/// update (one global withAnimation, or one Animatable vector, would merge them).
private struct IslandSurfaceWidthFX: ViewModifier, Animatable {
    var width: CGFloat
    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    func body(content: Content) -> some View {
        content.transformEnvironment(\.islandSurface) { $0.width = width }
    }
}

private struct IslandSurfaceHeightFX: ViewModifier, Animatable {
    var height: CGFloat
    var top: CGFloat
    var bottom: CGFloat
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(height, AnimatablePair(top, bottom)) }
        set { height = newValue.first; top = newValue.second.first; bottom = newValue.second.second }
    }

    func body(content: Content) -> some View {
        content.transformEnvironment(\.islandSurface) {
            $0.height = height
            $0.top = top
            $0.bottom = bottom
        }
    }
}

private struct IslandHeightKey: Equatable {
    let height: CGFloat
    let top: CGFloat
    let bottom: CGFloat
}

extension View {
    /// Publishes `g` as the animated `islandSurface` environment for the shape and mask views
    /// inside. Width: 150/20 growing, 200/20 collapsing. Height + radii: 250/21 expanding,
    /// 250/25 collapsing. `reduce` (Reduce Motion, settings previews): a short 0.2 s ease.
    func islandSurface(_ g: IslandSurfaceGeometry, widthGrowing: Bool, heightGrowing: Bool,
                       reduce: Bool = false) -> some View {
        modifier(IslandSurfaceWidthFX(width: g.width))
            .animation(reduce ? IslandMotion.crossFade : IslandMotion.width(growing: widthGrowing), value: g.width)
            .modifier(IslandSurfaceHeightFX(height: g.height, top: g.top, bottom: g.bottom))
            .animation(reduce ? IslandMotion.crossFade : IslandMotion.height(growing: heightGrowing),
                       value: IslandHeightKey(height: g.height, top: g.top, bottom: g.bottom))
    }
}

/// The notch island's black shape at the animated surface geometry (ears outside the body).
struct NotchSurfaceShape: View {
    @Environment(\.islandSurface) private var g

    var body: some View {
        NotchShape(topRadius: g.top, bottomRadius: g.bottom)
            .fill(Color.black)
            .frame(width: max(0, g.width + 2 * g.top), height: max(0, g.height))
    }
}

/// Clips island content to the animated body (without the ears).
struct NotchSurfaceMask: View {
    @Environment(\.islandSurface) private var g

    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: g.bottom, bottomTrailingRadius: g.bottom)
            .frame(width: max(0, g.width), height: max(0, g.height))
    }
}

/// Black capsule / card with a tight shadow under it (CSS: 0 8px 24px -10px rgba(0,0,0,.5);
/// the -10 spread is the padding of the blurred copy), at a fixed or the animated geometry.
struct CapsuleBackdrop: View {
    var radius: CGFloat
    var hanging = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(0, radius), style: .continuous)
        shape.fill(Color.black)
            .background(
                shape.fill(Color.black.opacity(hanging ? 0.6 : 0.5))
                    .padding(hanging ? 12 : 10)
                    .offset(y: hanging ? 12 : 8)
                    .blur(radius: hanging ? 15 : 12))
    }
}

struct CapsuleSurfaceShape: View {
    var hanging = false
    @Environment(\.islandSurface) private var g

    var body: some View {
        CapsuleBackdrop(radius: g.bottom, hanging: hanging)
            .frame(width: max(0, g.width), height: max(0, g.height))
    }
}

struct CapsuleSurfaceMask: View {
    @Environment(\.islandSurface) private var g

    var body: some View {
        RoundedRectangle(cornerRadius: max(0, g.bottom), style: .continuous)
            .frame(width: max(0, g.width), height: max(0, g.height))
    }
}

// MARK: - Glyphs

struct IslandMicBadge: View {
    let mode: Mode
    var formula = false
    var body: some View {
        ZStack {
            Circle().fill(Palette.accent(mode).opacity(0.22))
            Image(systemName: mode == .ocr ? (formula ? "function" : "text.viewfinder") : "mic.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.accent(mode))
        }
        .frame(width: 20, height: 20)
    }
}

/// Texterkennung while the crosshair is out: what the user is doing, in the mode colour, and the
/// way to formulas (05.10.: a tap on ⌥; holding it would make macOS draw the region from its centre)
struct IslandSelectHint: View {
    var formula = false
    var body: some View {
        HStack(spacing: 7) {
            Text(formula ? L("Formel wählen") : L("Bereich wählen"))
                .foregroundStyle(Palette.accent(.ocr).opacity(0.9))
            if !formula {
                Text(L("⌥ Formel")).foregroundStyle(.white.opacity(0.42))
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .fixedSize()
        .animation(.easeOut(duration: 0.18), value: formula)
    }
}

struct IslandRecDot: View {
    var body: some View {
        Circle().fill(Palette.rec)
            .frame(width: 6, height: 6)
            .background(Circle().fill(Palette.rec.opacity(0.18)).frame(width: 12, height: 12))
    }
}

struct IslandCheckBadge: View {
    let mode: Mode
    var body: some View {
        Circle().fill(Palette.accent(mode))
            .frame(width: 20, height: 20)
            .overlay(
                IslandCheckGlyph()
                    .stroke(Color.black, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .frame(width: 11, height: 11))
    }
}

struct IslandErrorBadge: View {
    var body: some View {
        ZStack {
            Circle().fill(Palette.rec.opacity(0.22))
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(hex: 0xFF6B61))
        }
        .frame(width: 20, height: 20)
    }
}

struct IslandKeyCap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.14)))
    }
}

struct IslandTimerText: View {
    let start: Date
    let frozen: TimeInterval?

    var body: some View {
        if let frozen {
            label(frozen)
        } else {
            TimelineView(.periodic(from: start, by: 1)) { ctx in
                label(ctx.date.timeIntervalSince(start))
            }
        }
    }

    private func label(_ t: TimeInterval) -> some View {
        Text(IslandCopy.timer(t))
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize()
    }
}

/// Slow processing (04.10., decided by Nils): from 5 s the right ear counts the seconds; from
/// 10 s, and only once the take runs twice as long as usual for its length on this Mac (the core
/// sends that as hint_after), a small card says "Dauert länger" and which hotkey cancels.
enum IslandSlow {
    static let count: TimeInterval = 5
    static let hint: TimeInterval = 10
}

struct IslandSlowSeconds: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            Text("\(max(Int(IslandSlow.count), Int(ctx.date.timeIntervalSince(since)))) s")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize()
        }
    }
}

struct IslandSlowBody: View {
    let hotkey: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(L("Dauert länger"))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
            Spacer(minLength: 8)
            Text(L("%@ bricht ab", hotkey))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IslandRingSpinner: View {
    let mode: Mode
    var still: Double?

    var body: some View {
        if let still {
            ring(still * 360)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
                ring(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360)
            }
        }
    }

    private func ring(_ degrees: Double) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 1.9)
            Circle().trim(from: 0, to: 0.3)
                .stroke(Palette.accent(mode), style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
                .rotationEffect(.degrees(degrees - 90))
        }
        .frame(width: 12, height: 12)
        .frame(width: 16, height: 16)
    }
}

// MARK: - Waveform

/// Thin, calm level meter. fein = 4 bars, sym = 7 centre-weighted bars, linie = 24×14 line.
/// Bars are 2 pt wide with 1.5 pt gaps, 2…14 pt tall (dots in silence), vertical gradient
/// accentLo → accentHi. Live: driven by the 7 microphone bands with attack 0.3 / release 0.1
/// per 60 Hz frame (time-corrected); otherwise a calm synthetic speech rhythm.
struct WaveformView: View {
    let style: WaveStyle
    let mode: Mode
    let live: Bool
    let levels: () -> [Float]
    /// non-nil → one deterministic frame at this time, no smoothing
    var still: Double?

    @State private var engine = IslandWaveEngine()

    static func width(_ style: WaveStyle) -> CGFloat {
        switch style {
        case .fein: return 4 * 2 + 3 * 1.5
        case .sym: return 7 * 2 + 6 * 1.5
        case .linie: return 24
        }
    }

    var body: some View {
        Group {
            if let still {
                canvas(t: still, smooth: false)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
                    canvas(t: ctx.date.timeIntervalSinceReferenceDate, smooth: true)
                }
            }
        }
        .frame(width: Self.width(style), height: IslandMetrics.waveHeight)
        .accessibilityHidden(true)
    }

    private func canvas(t: Double, smooth: Bool) -> some View {
        let style = style, mode = mode, live = live, levels = levels, engine = engine
        return Canvas { gc, size in
            let bands = levels()
            if style == .linie {
                let level = IslandWaveMath.lineLevel(bands)
                let hist = engine.lineHistory(level: level, t: t, smooth: smooth)
                IslandWaveMath.drawLine(gc, size: size, t: t, live: live, history: hist, mode: mode)
            } else {
                let targets = IslandWaveMath.barTargets(style: style, t: t, live: live, bands: bands)
                let heights = smooth ? engine.smooth(targets, t: t) : targets
                IslandWaveMath.drawBars(gc, size: size, heights: heights, mode: mode)
            }
        }
    }
}

/// Per-view smoothing state, mutated from the Canvas renderer on every frame.
final class IslandWaveEngine {
    private var heights: [CGFloat] = []
    private var lastBarT: Double?
    private var history = [CGFloat](repeating: 0, count: IslandWaveMath.linePoints)
    private var lastLineT: Double?
    private var lineClock: Double = 0

    func smooth(_ targets: [CGFloat], t: Double) -> [CGFloat] {
        if heights.count != targets.count { heights = targets.map { _ in IslandWaveMath.minBar } }
        let dt = lastBarT.map { min(max(t - $0, 0), 0.1) } ?? (1.0 / 60)
        lastBarT = t
        let frames = dt * 60
        for i in heights.indices {
            let a: Double = targets[i] > heights[i] ? 0.3 : 0.1
            let k = CGFloat(1 - pow(1 - a, frames))
            heights[i] += (targets[i] - heights[i]) * k
        }
        return heights
    }

    /// shifts one sample per 1/60 s, so the line keeps ~0.3 s of history at any refresh rate
    func lineHistory(level: CGFloat, t: Double, smooth: Bool) -> [CGFloat] {
        guard smooth else { return [CGFloat](repeating: level, count: IslandWaveMath.linePoints) }
        let dt = lastLineT.map { min(max(t - $0, 0), 0.25) } ?? 0
        lastLineT = t
        lineClock += dt
        while lineClock >= 1.0 / 60 {
            lineClock -= 1.0 / 60
            history.removeFirst()
            let prev = history.last ?? 0
            let a: CGFloat = level > prev ? 0.3 : 0.1
            history.append(prev + (level - prev) * a * 2.2)
        }
        return history
    }
}

enum IslandWaveMath {
    static let minBar: CGFloat = 2
    static let maxBar: CGFloat = 14
    static let barWidth: CGFloat = 2
    static let gap: CGFloat = 1.5
    static let linePoints = 18

    /// speech-like loudness: syllables at ~4 Hz inside ~2.6 s phrases, short pauses between
    static func speech(_ t: Double) -> Double {
        let gate: Double = t.truncatingRemainder(dividingBy: 3.1) < 2.6 ? 1 : 0
        let syl = 0.5 + 0.5 * sin(t * 27.0) * sin(t * 10.7 + 1.3)
        return gate * (0.15 + 0.85 * max(0, syl))
    }

    static func jitter(_ i: Int, _ t: Double) -> Double {
        let d = Double(i)
        return 0.5 + 0.5 * sin(t * (3.4 + d * 0.9) + d * 2.1) * sin(t * (1.7 + d * 0.5) + d)
    }

    private static func band(_ b: [Float], _ i: Int) -> Double {
        i < b.count ? Double(max(0, min(1, b[i]))) : 0
    }

    private static func pair(_ b: [Float], _ i: Int, _ j: Int) -> Double { (band(b, i) + band(b, j)) / 2 }

    static func barTargets(style: WaveStyle, t: Double, live: Bool, bands b: [Float]) -> [CGFloat] {
        let n = style == .fein ? 4 : 7
        let c = Double(n - 1) / 2
        let silent = (b.max() ?? 0) < 0.02
        return (0..<n).map { i -> CGFloat in
            let d = abs(Double(i) - c)
            var v: Double
            if live {
                if silent {
                    v = 0
                } else if style == .sym {
                    // mirrored: centre = low-mid voice energy, edges = highs, gently tapered
                    let groups = [pair(b, 0, 1), pair(b, 2, 3), pair(b, 4, 5), band(b, 6)]
                    let weight = [1.0, 0.86, 0.7, 0.55]
                    let k = min(3, Int(d.rounded()))
                    v = groups[k] * weight[k]
                } else {
                    // speech's spectral tilt keeps the high bands at about half the energy of
                    // the low ones: lift them per group, so the four bars read balanced
                    let groups = [min(1, pair(b, 2, 3) * 1.1), pair(b, 0, 1), pair(b, 1, 2),
                                  min(1, pair(b, 4, 5) * 1.7)]
                    v = groups[i] * 0.95
                }
            } else {
                let env = speech(t)
                let shape = style == .sym ? exp(-(d * d) / (2 * pow(c * 0.6, 2))) : 1
                v = 0.8 * env * shape * (0.5 + 0.5 * jitter(i, t))
            }
            return minBar + CGFloat(max(0, min(1, v))) * (maxBar - minBar)
        }
    }

    static func lineLevel(_ b: [Float]) -> CGFloat {
        guard !b.isEmpty else { return 0 }
        let mean = b.reduce(0, +) / Float(b.count)
        return CGFloat(min(1, max(0, mean * 1.5)))
    }

    static func drawBars(_ gc: GraphicsContext, size: CGSize, heights: [CGFloat], mode: Mode) {
        let n = heights.count
        let total = CGFloat(n) * barWidth + CGFloat(n - 1) * gap
        var x = (size.width - total) / 2
        let gradient = Gradient(colors: [Palette.accentLo(mode), Palette.accentHi(mode)])
        for h in heights {
            let hh = max(minBar, min(maxBar, h))
            let r = CGRect(x: x, y: (size.height - hh) / 2, width: barWidth, height: hh)
            gc.fill(Path(roundedRect: r, cornerRadius: barWidth / 2),
                    with: .linearGradient(gradient, startPoint: CGPoint(x: r.midX, y: r.maxY),
                                          endPoint: CGPoint(x: r.midX, y: r.minY)))
            x += barWidth + gap
        }
    }

    static func drawLine(_ gc: GraphicsContext, size: CGSize, t: Double, live: Bool,
                         history: [CGFloat], mode: Mode) {
        var p = Path()
        let n = linePoints
        let mid = size.height / 2
        for k in 0..<n {
            let x = CGFloat(k) / CGFloat(n - 1) * size.width
            let taper = sin(Double.pi * Double(k) / Double(n - 1))
            let amp = live ? Double(history[k]) * 4.8 : speech(t - Double(n - k) * 0.03) * 4.2
            let wobble = sin(Double(k) * 0.95 + t * 11) * cos(Double(k) * 0.31 - t * 3.7)
            let y = min(size.height - 0.8, max(0.8, mid + CGFloat(taper * amp * wobble)))
            if k == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        let gradient = Gradient(colors: [Palette.accentLo(mode), Palette.accent(mode), Palette.accentHi(mode),
                                         Palette.accent(mode), Palette.accentLo(mode)])
        gc.stroke(p, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                  style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - Live text

/// Lays the text out at its full height, shows only the newest `maxLines` lines (bottom
/// aligned) and reports at most that height. The hidden second subview is a reference text
/// with exactly `maxLines` lines in the same font, so the cap uses SwiftUI's own metrics.
private struct IslandTailClipLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? IslandMetrics.liveWidth
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: w, height: nil))
        let cap = subviews[1].sizeThatFits(ProposedViewSize(width: w, height: nil))
        return CGSize(width: w, height: min(text.height, cap.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = bounds.width
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: w, height: nil))
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading,
                          proposal: ProposedViewSize(width: w, height: text.height))
        subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: w, height: nil))
    }
}

enum IslandLiveText {
    static var nsFont: NSFont { .systemFont(ofSize: IslandMetrics.liveFontSize) }
    static var font: Font { .system(size: IslandMetrics.liveFontSize) }

    /// Splits off the last `brightWords` words (the rest keeps its trailing whitespace).
    static func split(_ text: String, brightWords: Int) -> (old: String, tail: String) {
        guard brightWords > 0 else { return (text, "") }
        var count = 0
        var inWord = false
        var i = text.endIndex
        while i > text.startIndex {
            let j = text.index(before: i)
            let space = text[j].isWhitespace
            if !space { inWord = true }
            if space && inWord {
                count += 1
                inWord = false
                if count == brightWords { return (String(text[..<i]), String(text[i...])) }
            }
            i = j
        }
        return ("", text)
    }

    private static var caretCache: [Mode: NSImage] = [:]

    /// baseline → ascender. Measured: any baselineOffset on an inline image, or an image taller
    /// than the ascender, makes its line 1–7 pt taller, so the caret sits on the baseline.
    static let caretSize = CGSize(width: 4.5, height: 13)

    /// thin caret in the mode colour (2 pt bar after a 2.5 pt gap), drawn as an inline image
    static func caret(_ mode: Mode) -> NSImage {
        if let img = caretCache[mode] { return img }
        let color = NSColor(Palette.accent(mode))
        let size = caretSize
        let img = NSImage(size: size, flipped: false) { _ in
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: size.width - 2, y: 0, width: 2, height: size.height),
                         xRadius: 1, yRadius: 1).fill()
            return true
        }
        caretCache[mode] = img
        return img
    }

    static func caretText(_ mode: Mode) -> Text {
        Text(Image(nsImage: caret(mode)))
    }

    /// exactly `liveMaxLines` lines in the live font (+ caret on the last one, if shown)
    static func reference(caret mode: Mode?) -> Text {
        let lines = Text(Array(repeating: "X", count: IslandMetrics.liveMaxLines).joined(separator: "\n"))
        guard let mode else { return lines }
        return lines + caretText(mode)
    }

    /// line count NSLayoutManager predicts (used only as the animation key for height changes)
    static func estimatedLines(_ text: String, width: CGFloat, caret: Bool) -> Int {
        guard width > 0 else { return 1 }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = IslandMetrics.liveLineSpacing
        let attr = NSMutableAttributedString(string: text, attributes: [.font: nsFont, .paragraphStyle: para])
        if caret {
            let att = NSTextAttachment()
            att.bounds = CGRect(origin: .zero, size: caretSize)
            attr.append(NSAttributedString(attachment: att))
        }
        if attr.length == 0 { return 1 }
        let storage = NSTextStorage(attributedString: attr)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var lines = 0
        var index = 0
        while index < layout.numberOfGlyphs {
            var range = NSRange()
            layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            index = NSMaxRange(range)
            lines += 1
        }
        return max(1, lines)
    }
}

/// Variant B body: the live transcript. Older words dim white 50 %, the newest bright with a
/// thin caret in the mode colour; while processing a shimmer sweeps over the whole text.
struct IslandLiveTextView: View {
    let text: String
    let brightWords: Int
    let mode: Mode
    let processing: Bool
    let overflowing: Bool
    var still: Double?
    var reduceMotion = false

    var body: some View {
        IslandTailClipLayout {
            content
            IslandLiveText.reference(caret: processing ? nil : mode)
                .font(IslandLiveText.font)
                .lineSpacing(IslandMetrics.liveLineSpacing)
                .hidden()
        }
        .clipped()
        .mask(fade)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    @ViewBuilder private var content: some View {
        if processing {
            if reduceMotion {
                styled(Text(text).foregroundStyle(.white.opacity(0.7)))
            } else if let still {
                shimmer(phase: still)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
                    shimmer(phase: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
        } else if text.isEmpty {
            caretOnly
        } else {
            let parts = IslandLiveText.split(text, brightWords: brightWords)
            styled(Text(parts.old).foregroundStyle(.white.opacity(0.5))
                + Text(parts.tail).foregroundStyle(.white.opacity(0.95))
                + IslandLiveText.caretText(mode))
        }
    }

    private func styled(_ t: Text) -> some View {
        t.font(IslandLiveText.font)
            .lineSpacing(IslandMetrics.liveLineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// light sweeping over the text every 1.6 s (CSS reference: 220 % background, linear)
    private func shimmer(phase t: Double) -> some View {
        let p = -0.7 + 2.4 * (t / 1.6 - floor(t / 1.6))
        let g = LinearGradient(
            stops: [.init(color: .white.opacity(0.42), location: 0),
                    .init(color: .white.opacity(0.98), location: 0.5),
                    .init(color: .white.opacity(0.42), location: 1)],
            startPoint: UnitPoint(x: p - 0.7, y: 0.5), endPoint: UnitPoint(x: p + 0.7, y: 0.5))
        return styled(Text(text).foregroundStyle(g))
    }

    /// nothing transcribed yet: a softly blinking caret says "listening"
    @ViewBuilder private var caretOnly: some View {
        let caret = styled(Text("\u{200B}") + IslandLiveText.caretText(mode))
        if reduceMotion || still != nil {
            caret
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                caret.opacity(0.35 + 0.65 * (0.5 + 0.5 * cos(t * .pi / 0.55)))
            }
        }
    }

    /// once older lines scroll out at the top, they fade instead of being cut hard
    private var fade: some View {
        LinearGradient(stops: [.init(color: .black.opacity(overflowing ? 0.15 : 1), location: 0),
                               .init(color: .black, location: overflowing ? 0.34 : 0)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// done card body: title + dim meta, then the preview (hovered: the whole text + copy row)
struct IslandDoneBody: View {
    let done: DoneInfo
    let mode: Mode
    let previewLines: Int
    var keepLines = false
    var showMeta = true
    var expanded = false
    var still = false
    var reduce = false
    var stillCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text(IslandCopy.title(done, mode: mode))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
             + Text(showMeta ? IslandCopy.meta(done) : "")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5)))
                .lineLimit(1)
                .truncationMode(.middle)
            IslandDoneText(done: done, mode: mode, previewLines: previewLines, keepLines: keepLines,
                           expanded: expanded, still: still, reduce: reduce, stillCopied: stillCopied)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The text part of every done card: the preview, or on hover (SPEC §0) the whole text with the
/// copy row under it. The incoming block enters with the §0 enter transition, the outgoing one
/// hands over with a quick fade (`islandHandOver`). The card animates its frame on the width
/// spring when `expanded` changes (compact cards widen, live cards only grow taller), so rows
/// that stay (badge, title, seconds) ride with the surface's edges and the change is animated.
struct IslandDoneText: View {
    let done: DoneInfo
    let mode: Mode
    let previewLines: Int
    var keepLines = false
    var expanded = false
    var still = false
    var reduce = false
    var stillCopied = false

    var body: some View {
        let t = AnyTransition.islandHandOver(reduce: reduce)
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if expanded {
                    IslandFullText(done: done, still: still).transition(t)
                } else {
                    IslandPreviewText(done: done, lines: previewLines, keepLines: keepLines).transition(t)
                }
            }
            if expanded, let c = done.context, c.used || c.noteworthy {
                IslandContextSection(info: c)
                    .padding(.top, 10)
                    .transition(t)
            }
            if expanded && !done.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 8) {
                    IslandCopyButton(text: done.fullText, mode: mode, still: still, stillCopied: stillCopied)
                    if let c = done.context, c.used, !c.bundle.isEmpty, !c.app.isEmpty {
                        IslandContextOffButton(app: c.app, bundle: c.bundle, still: still)
                    }
                }
                .padding(.top, 10)
                .transition(t)
            }
        }
    }
}

/// Sizes itself to the content's height, capped at the reference text's height (12 lines) plus
/// half a line: when text continues, a half line peeks out under the fade, so the cut never
/// lands on a line boundary and reads as the end of the text.
/// Subviews: [0] the content (hidden, measures), [1] the reference (hidden), [2] what is shown.
private struct IslandCappedHeightLayout: Layout {
    static func limit(reference: CGFloat) -> CGFloat {
        reference + reference / CGFloat(IslandMetrics.fullTextMaxLines) / 2
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? IslandMetrics.hoverWidth
        let content = subviews[0].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
        let reference = subviews[1].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
        return CGSize(width: w, height: min(content, Self.limit(reference: reference)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let free = ProposedViewSize(width: bounds.width, height: nil)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: free)
        subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: free)
        subviews[2].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// SPEC §0 (03.10.): the whole final text of a hovered confirmation. Up to ~12 lines; longer
/// text scrolls, with a soft fade wherever more text continues (bottom, and top once scrolled).
/// Stills draw the unscrolled state without a ScrollView (ImageRenderer cannot draw one).
struct IslandFullText: View {
    let done: DoneInfo
    var still = false

    @State private var contentHeight: CGFloat = 0
    @State private var referenceHeight: CGFloat = 0
    @State private var edges: Edges?

    private struct Edges: Equatable {
        var above: Bool
        var below: Bool
    }

    private static let font = Font.system(size: 12.5)
    private static let lineSpacing: CGFloat = 2.5
    private static let fadeTop: CGFloat = 16
    private static let fadeBottom: CGFloat = 26

    private var overflowing: Bool {
        referenceHeight > 0 && contentHeight > IslandCappedHeightLayout.limit(reference: referenceHeight) + 0.5
    }
    /// four lines fewer when the context section sits under the text, so the card stays in the panel
    private var maxLines: Int {
        let ctx = done.context.map { $0.used || $0.noteworthy } ?? false
        return IslandMetrics.fullTextMaxLines - (ctx ? 4 : 0)
    }
    private var fadeAbove: Bool { edges?.above ?? false }
    private var fadeBelow: Bool { edges?.below ?? overflowing }

    var body: some View {
        let paragraphs = IslandCopy.paragraphs(done)
        IslandCappedHeightLayout {
            text(paragraphs)
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            Text(Array(repeating: "X", count: maxLines).joined(separator: "\n"))
                .font(Self.font)
                .lineSpacing(Self.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { referenceHeight = $0 }
            if still {
                text(paragraphs)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
            } else {
                ScrollView(.vertical) {
                    text(paragraphs)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: Edges.self) { geo in
                    Edges(above: geo.visibleRect.minY > 0.5,
                          below: geo.visibleRect.maxY < geo.contentSize.height - 0.5)
                } action: { _, new in
                    edges = new
                }
            }
        }
        .mask(fade)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(done.fullText)
    }

    private func text(_ paragraphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: IslandMetrics.fullTextParagraphGap) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                Text(p)
                    .font(Self.font)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineSpacing(Self.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// solid in the middle; the ends fade only where more text continues
    private var fade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(fadeAbove ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fadeTop)
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .black.opacity(fadeBelow ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fadeBottom)
        }
        .animation(still ? nil : .easeOut(duration: 0.2), value: Edges(above: fadeAbove, below: fadeBelow))
    }
}

/// Small "Kopieren" button on a hovered confirmation: puts the whole text on the pasteboard and
/// answers with "Kopiert" plus a check for a moment. Same vocabulary as the hub's copy chip
/// (text only, check once copied, continuous rounded rect) and the ⌘V key cap's fill; sized by
/// the wider of both labels, so it never jumps.
/// Trackpad haptics like Alcove's (04.10., Nils): a light tick when the pointer reaches the
/// confirmation, a firmer one on "Kopieren". Force Touch trackpads only, felt while a finger rests
/// on it; macOS's own haptics setting applies.
@MainActor
enum IslandHaptic {
    static func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func click() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
}

struct IslandCopyButton: View {
    let text: String
    let mode: Mode
    var still = false
    var stillCopied = false

    @State private var copied = false
    @State private var resetWork: DispatchWorkItem?

    var body: some View {
        let done = copied || stillCopied
        Button(action: copy) {
            ZStack {
                label(copied: false).hidden()
                label(copied: true).hidden()
                label(copied: done)
            }
            .foregroundStyle(done ? Palette.accent(mode) : .white.opacity(0.86))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.14)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(IslandPressStyle())
        .onHover { inside in if inside && !still { IslandHaptic.tick() } }
        .accessibilityLabel(done ? L("Kopiert") : L("Text kopieren"))
    }

    private func label(copied: Bool) -> some View {
        HStack(spacing: 4) {
            if copied { Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)) }
            Text(copied ? L("Kopiert") : L("Kopieren"))
        }
        .font(.system(size: 11.5, weight: .medium))
    }

    private func copy() {
        guard !still else { return }
        // Texterkennung: the whole result again, the table for Notizen and Numbers included
        let whole = mode == .ocr && MainActor.assumeIsolated { ScreenText.shared?.copyLast(text) ?? false }
        if !whole {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        IslandHaptic.click()
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        resetWork?.cancel()
        let work = DispatchWorkItem { withAnimation(.easeInOut(duration: 0.25)) { copied = false } }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}

private struct IslandPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IslandPreviewText: View {
    let done: DoneInfo
    let lines: Int
    var keepLines = false

    var body: some View {
        Text(IslandCopy.preview(done, keepLines: keepLines))
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.88))
            .lineSpacing(2.5)
            .lineLimit(lines)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IslandErrorBody: View {
    let message: String
    var body: some View {
        // centred under the notch (Nils 04.10.): a short notice sits in the middle, not at the left
        Text(message)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.88))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Root

/// Fills the transparent panel; the island (notch) or the capsule animates inside it.
struct IslandView: View {
    let state: AppState
    let model: IslandModel

    /// the panel's content area (canvas points, top-left origin): card frames are reported in it
    static let space = "VoiceBud.islandCanvas"

    /// Reduce Motion identity: each phase, and the hovered confirmation, is its own island
    private struct FadeID: Hashable {
        let phase: Phase
        let expanded: Bool
    }

    var body: some View {
        let fadeID = FadeID(phase: model.phase, expanded: model.hover == .expanded)
        ZStack(alignment: .top) {
            // Reduce Motion: no morphing, each state is its own island and they cross-fade
            switch (model.kind, model.reduceMotion) {
            case (.notch, false):
                NotchIslandView(state: state, model: model, hover: model.hover)
            case (.notch, true):
                NotchIslandView(state: state, model: model, hover: model.hover)
                    .id(fadeID)
                    .transition(.opacity)
            case (.capsule, false):
                CapsuleView(state: state, model: model, hover: model.hover)
                    .padding(.top, model.capsuleTop)
            case (.capsule, true):
                CapsuleView(state: state, model: model, hover: model.hover)
                    .padding(.top, model.capsuleTop)
                    .id(fadeID)
                    .transition(.opacity)
            }
        }
        .frame(width: model.canvas.width, height: model.canvas.height, alignment: .top)
        .coordinateSpace(.named(Self.space))
        .environment(\.colorScheme, .dark)
        // only a hovered confirmation takes clicks (copy button, scrolling); the panel itself
        // ignores the mouse everywhere else (IslandController)
        .allowsHitTesting(model.hover == .expanded)
        .onChange(of: state.partialText) { old, new in
            model.noteLiveText(old: old, new: new)
        }
    }
}

/// Reports the surface's animated body rect (canvas points) for the controller's pointer
/// polling. Invisible, takes no clicks, does not change the surface's size.
struct IslandSurfaceHitArea: View {
    let model: IslandModel
    @Environment(\.islandSurface) private var g

    var body: some View {
        Color.clear
            .frame(width: max(0, g.width), height: max(0, g.height))
            .allowsHitTesting(false)
            .islandReportsCardFrame(model)
    }
}

extension View {
    /// writes this view's frame in the island canvas into `model.cardFrame` (not observed)
    func islandReportsCardFrame(_ model: IslandModel) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(IslandView.space)) } action: {
            model.cardFrame = $0
        }
    }
}

// MARK: - Island at the notch (compact, or dropping down with live text)

struct NotchIslandView: View {
    let state: AppState
    let model: IslandModel
    /// `model.hover`, handed in as a value: with Reduce Motion the outgoing island of a
    /// cross-fade keeps showing its own (folded or unfolded) card
    var hover: IslandModel.Hover = .none
    /// measured height of the ear row + body (drives the surface height spring)
    @State private var contentHeight: CGFloat = 0

    /// (Texterkennung has no live text: "Bereich wählen" keeps its own small shape)
    private var live: Bool { model.flavour == .live && model.mode != .ocr }
    private var phase: Phase { model.phase }
    private var reduce: Bool { model.reduceMotion }
    /// stills and Reduce Motion: the shape is simply sized by its content, nothing morphs
    private var layoutMode: Bool { model.stillTime != nil || reduce }
    private var active: Bool { phase == .recording || phase == .processing }
    private var cardPhase: Bool { phase == .done || phase == .error }
    /// geometry as if shown; with Reduce Motion the island fades instead of growing from the notch
    private var shown: Bool { model.presented || (reduce && phase != .idle) }
    /// SPEC §0 (03.10.): the pointer rests on the confirmation, the same card shows the whole text
    private var expanded: Bool { shown && phase == .done && hover == .expanded }
    /// folding back after a hover runs on the collapse springs
    private var growing: Bool { shown && hover != .collapsed }

    /// collapsed: a little smaller than the hardware notch, so it vanishes behind it whatever
    /// the real corner radius is
    private var bodyWidth: CGFloat {
        guard shown else { return model.notch.width - 8 }
        if phase == .error {
            return IslandCopy.notchErrorWidth(errorText, notch: model.notch.width)
        }
        if live { return IslandMetrics.liveWidth }
        if expanded { return IslandMetrics.hoverWidth }
        if phase == .recording && model.mode == .ocr {                 // "Bereich wählen  ⌥ Formel" or "Formel wählen"
            return model.notch.width + 2 * (state.ocrFormula ? 112 : 150)
        }
        return phase == .done ? IslandMetrics.doneWidth : model.notch.width + 2 * IslandMetrics.earWidth
    }

    /// the error or notice card's text in the current language (the core sends German)
    private var errorText: String { IslandCopy.message(model.errorMessage ?? "Fehler") }

    /// processing past 5 s with the card look: a small body says so (compact flavour only;
    /// with live text the seconds go to the ear)
    private var slowCard: Bool { phase == .processing && model.slowHint && !live }

    private var hasBody: Bool { shown && (cardPhase || (live && active) || slowCard) }

    /// SPEC §0: ear ≈ 8 collapsed, 13 expanded
    private var topRadius: CGFloat {
        guard shown else { return 0 }
        return hasBody ? 13 : 8
    }

    /// SPEC §0: bottom ≈ 12 collapsed, 19 card, 24 live (and a hovered card, as wide as live)
    private var bottomRadius: CGFloat {
        guard shown else { return min(9, model.notch.height / 3) }
        if !hasBody { return 12 }
        return live || expanded ? 24 : 19
    }

    /// closed = exactly the hardware notch: opening then only widens the compact island. Starting
    /// 4 pt shorter made it grow down while it grew out, which read as a diagonal at the start.
    private var surfaceHeight: CGFloat {
        guard shown else { return model.notch.height }
        return hasBody ? max(model.notch.height, contentHeight) : model.notch.height
    }

    private var textWidth: CGFloat { bodyWidth - 2 * IslandMetrics.bodyPad }

    private var liveLines: Int {
        guard live, active else { return 0 }
        return IslandLiveText.estimatedLines(state.partialText, width: textWidth, caret: phase == .recording)
    }

    private var contentKey: IslandContentKey {
        IslandContentKey(phase: phase, presented: model.presented, flavour: model.flavour,
                         slow: model.slowHint ? 2 : model.slowSince != nil ? 1 : 0)
    }

    var body: some View {
        let lines = liveLines
        if layoutMode {
            contentStack(lines: lines)
                .frame(minHeight: model.notch.height, alignment: .top)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: bottomRadius, bottomTrailingRadius: bottomRadius))
                .background(alignment: .top) {
                    NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                        .fill(Color.black)
                        .padding(.horizontal, -topRadius)
                }
                .islandReportsCardFrame(model)
                .opacity(reduce && !model.presented ? 0 : 1)
        } else {
            ZStack(alignment: .top) {
                NotchSurfaceShape()
                IslandSurfaceHitArea(model: model)
                contentStack(lines: lines)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    .mask(alignment: .top) { NotchSurfaceMask() }
            }
            .islandSurface(IslandSurfaceGeometry(width: bodyWidth, height: surfaceHeight,
                                                 top: topRadius, bottom: bottomRadius),
                           widthGrowing: growing, heightGrowing: growing && hasBody)
        }
    }

    /// Laid out at the target width (text never re-wraps while the shape springs); the
    /// animated surface reveals it. On hover the frame widens on the width spring, so the
    /// badge, the seconds and the title ride with the edges instead of jumping.
    private func contentStack(lines: Int) -> some View {
        VStack(spacing: 0) {
            earRow
            if hasBody {
                bodyContent(lines: lines)
                    .transition(.islandEnter(toward: .top, reduce: reduce))
            }
        }
        .animation(layoutMode ? nil : IslandMotion.swap, value: contentKey)
        .frame(width: bodyWidth, alignment: .top)
        // keyed on the hover only: phase changes keep their own (swap) timing
        .animation(layoutMode ? nil : IslandMotion.width(growing: growing), value: expanded)
    }

    private var earRow: some View {
        HStack(spacing: 0) {
            leftEar
                .padding(.leading, IslandMetrics.earPad)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.notch.width)
            rightEar
                .padding(.trailing, IslandMetrics.earPad)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: model.notch.height)
    }

    private var leftEar: some View {
        let t = AnyTransition.islandGlyph(swap: model.contentSwap, toward: .trailing, reduce: reduce)
        return HStack(spacing: 7) {
            if shown && active { IslandMicBadge(mode: model.mode, formula: state.ocrFormula).transition(t) }
            if shown && phase == .recording && model.mode != .ocr { IslandRecDot().transition(t) }
            if shown && phase == .recording && live && model.mode != .ocr {
                IslandTimerText(start: model.recordingStart, frozen: model.frozenElapsed).transition(t)
            }
            if shown && phase == .done { IslandCheckBadge(mode: model.mode).transition(t) }
            if shown && phase == .error && model.noticeOK { IslandCheckBadge(mode: model.mode).transition(t) }
            if shown && phase == .error && !model.noticeOK { IslandErrorBadge().transition(t) }
        }
    }

    private var rightEar: some View {
        let t = AnyTransition.islandGlyph(swap: model.contentSwap, toward: .leading, reduce: reduce)
        return ZStack(alignment: .trailing) {
            if shown && phase == .recording && model.mode == .ocr {
                IslandSelectHint(formula: state.ocrFormula).transition(t)   // Texterkennung: the user drags a region
            } else if shown && phase == .recording {
                WaveformView(style: state.settings.waveStyle, mode: model.mode, live: state.settings.waveLive,
                             levels: { [state] in state.bands }, still: model.stillTime)
                    .transition(t)
            }
            if shown && phase == .processing {
                HStack(spacing: 6) {
                    if let since = model.slowSince {
                        IslandSlowSeconds(since: since)
                            .transition(.islandGlyph(swap: true, toward: .leading, reduce: reduce))
                    }
                    IslandRingSpinner(mode: model.mode, still: model.stillTime.map { _ in 0.15 })
                }
                .animation(layoutMode ? nil : IslandMotion.swap, value: model.slowSince != nil)
                .transition(t)
            }
            if shown && phase == .done, let d = model.done {
                Group {
                    if d.toClipboard {
                        IslandKeyCap(label: "⌘V")
                    } else {
                        Text(IslandCopy.seconds(d.seconds))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .transition(t)
            }
        }
    }

    @ViewBuilder private func bodyContent(lines: Int) -> some View {
        // live text → done / error inside a body that stays: the old text leaves, the new
        // one enters (SPEC §0 leave / enter), instead of a plain cross-fade
        let swap = AnyTransition.islandEnter(toward: .top, reduce: reduce)
        ZStack(alignment: .topLeading) {
            if slowCard {
                IslandSlowBody(hotkey: HotkeyFormat.display(state.hotkeys["dictate"] ?? "ctrl+shift"))
                    .transition(swap)
            } else if active {
                IslandLiveTextView(text: state.partialText, brightWords: model.brightWords, mode: model.mode,
                                   processing: phase == .processing, overflowing: lines > IslandMetrics.liveMaxLines,
                                   still: model.stillTime, reduceMotion: reduce)
                    .transition(swap)
            } else if phase == .done, let d = model.done {
                IslandDoneBody(done: d, mode: model.mode, previewLines: live ? 5 : 1, keepLines: live,
                               expanded: expanded, still: model.stillTime != nil, reduce: reduce,
                               stillCopied: model.stillCopied)
                    .transition(swap)
            } else if phase == .error {
                IslandErrorBody(message: errorText)
                    .transition(swap)
            }
        }
        .padding(.horizontal, IslandMetrics.bodyPad)
        .padding(.top, 2)
        .padding(.bottom, live ? 16 : 13)
    }
}

// MARK: - Capsule (no notch, islandStyle "kapsel", Alcove "dodge")

/// One black capsule that grows out of a 36×8 pill at its anchor and morphs between the pill
/// (recording, processing), the done card and the error card. With live text a second surface,
/// the live card, hangs 6 pt below it while recording and processing.
struct CapsuleView: View {
    let state: AppState
    let model: IslandModel
    /// `model.hover` as a value (see NotchIslandView)
    var hover: IslandModel.Hover = .none
    @State private var pillWidth: CGFloat = 0
    @State private var doneHeight: CGFloat = 0
    @State private var errorHeight: CGFloat = 0
    @State private var liveHeight: CGFloat = 0

    /// (Texterkennung has no live text: "Bereich wählen" keeps its own small shape)
    private var live: Bool { model.flavour == .live && model.mode != .ocr }
    private var phase: Phase { model.phase }
    private var reduce: Bool { model.reduceMotion }
    private var layoutMode: Bool { model.stillTime != nil || reduce }
    private var active: Bool { phase == .recording || phase == .processing }
    private var shown: Bool { model.presented || (reduce && phase != .idle) }
    private var liveCardShown: Bool { shown && live && active }
    /// SPEC §0 (03.10.): the pointer rests on the confirmation, the same card shows the whole text
    private var expanded: Bool { shown && phase == .done && hover == .expanded }
    /// folding back after a hover runs on the collapse springs
    private var growing: Bool { shown && hover != .collapsed }
    private var cardWidth: CGFloat {
        if live { return IslandMetrics.liveWidth }
        return expanded ? IslandMetrics.hoverWidth : IslandMetrics.doneWidth
    }
    /// the error or notice card's text in the current language (the core sends German)
    private var errorText: String { IslandCopy.message(model.errorMessage ?? "Fehler") }
    private var errorWidth: CGFloat { IslandCopy.capsuleErrorWidth(errorText) }
    private var mainIsCard: Bool { phase == .done || phase == .error }

    private var contentKey: IslandContentKey {
        IslandContentKey(phase: phase, presented: model.presented, flavour: model.flavour,
                         slow: model.slowHint ? 2 : model.slowSince != nil ? 1 : 0)
    }

    var body: some View {
        if phase == .idle {
            // nothing on screen: no timelines keep running behind an ordered-out panel
            Color.clear.frame(width: 1, height: 1)
        } else if layoutMode {
            stillBody.opacity(reduce && !model.presented ? 0 : 1)
        } else {
            VStack(spacing: IslandMetrics.cardGap) {
                mainSurface
                if live { liveSurface }
            }
        }
    }

    // MARK: morphing (live)

    private var mainGeometry: IslandSurfaceGeometry {
        guard shown else {
            return IslandSurfaceGeometry(width: IslandMetrics.seed.width, height: IslandMetrics.seed.height,
                                         bottom: IslandMetrics.seed.height / 2)
        }
        switch phase {
        case .done:
            return IslandSurfaceGeometry(width: cardWidth, height: max(IslandMetrics.capsuleHeight, doneHeight),
                                         bottom: 22)
        case .error:
            let h = max(IslandMetrics.capsuleHeight, errorHeight)
            return IslandSurfaceGeometry(width: errorWidth, height: h, bottom: min(22, h / 2))
        default:
            return IslandSurfaceGeometry(width: pillWidth > 0 ? pillWidth : 128, height: IslandMetrics.capsuleHeight,
                                         bottom: IslandMetrics.capsuleHeight / 2)
        }
    }

    private var mainSurface: some View {
        ZStack(alignment: .top) {
            CapsuleSurfaceShape()
            IslandSurfaceHitArea(model: model)
            ZStack(alignment: .top) {
                if shown && active {
                    pill
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pillWidth = $0 }
                        .transition(.islandEnter(toward: .center, reduce: reduce))
                }
                if shown && phase == .done, let d = model.done {
                    doneCard(d)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { doneHeight = $0 }
                        .onDisappear { doneHeight = 0 }
                        .transition(.islandEnter(toward: .top, reduce: reduce))
                }
                if shown && phase == .error {
                    errorCard
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { errorHeight = $0 }
                        .transition(.islandEnter(toward: .top, reduce: reduce))
                }
            }
            .animation(IslandMotion.swap, value: contentKey)
            .mask(alignment: .top) { CapsuleSurfaceMask() }
        }
        .islandSurface(mainGeometry, widthGrowing: growing, heightGrowing: growing && mainIsCard)
    }

    private var liveSurface: some View {
        let geometry = liveCardShown
            ? IslandSurfaceGeometry(width: IslandMetrics.liveWidth,
                                    height: max(IslandMetrics.capsuleHeight, liveHeight), bottom: 22)
            : IslandSurfaceGeometry(width: IslandMetrics.seed.width, height: IslandMetrics.seed.height,
                                    bottom: IslandMetrics.seed.height / 2)
        return ZStack(alignment: .top) {
            CapsuleSurfaceShape(hanging: true)
            ZStack(alignment: .top) {
                if liveCardShown {
                    liveCardContent
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { liveHeight = $0 }
                        .transition(.islandEnter(toward: .top, reduce: reduce))
                }
            }
            .animation(IslandMotion.swap, value: contentKey)
            .mask(alignment: .top) { CapsuleSurfaceMask() }
        }
        .islandSurface(geometry, widthGrowing: liveCardShown, heightGrowing: liveCardShown)
        // grows out of / shrinks back into its tiny pill under the capsule, which must not linger
        .opacity(liveCardShown ? 1 : 0)
        .animation(liveCardShown ? .easeOut(duration: 0.12) : .easeIn(duration: 0.22).delay(0.1),
                   value: liveCardShown)
        .onChange(of: liveCardShown) { _, shownNow in if !shownNow { liveHeight = 0 } }
    }

    // MARK: stills and Reduce Motion

    @ViewBuilder private var stillBody: some View {
        VStack(spacing: IslandMetrics.cardGap) {
            switch phase {
            case .done:
                if let d = model.done {
                    doneCard(d).background(CapsuleBackdrop(radius: 22)).islandReportsCardFrame(model)
                }
            case .error:
                errorCard.background(CapsuleBackdrop(radius: 20))
            default:
                pill.fixedSize().background(CapsuleBackdrop(radius: IslandMetrics.capsuleHeight / 2))
            }
            if liveCardShown {
                liveCardContent.background(CapsuleBackdrop(radius: 22, hanging: true))
            }
        }
    }

    // MARK: content

    private var liveLines: Int {
        guard live, active else { return 0 }
        return IslandLiveText.estimatedLines(state.partialText, width: IslandMetrics.liveWidth - 36,
                                             caret: phase == .recording)
    }

    private var wave: some View {
        WaveformView(style: state.settings.waveStyle, mode: model.mode, live: state.settings.waveLive,
                     levels: { [state] in state.bands }, still: model.stillTime)
    }

    private var ring: some View { IslandRingSpinner(mode: model.mode, still: model.stillTime.map { _ in 0.15 }) }

    private var pill: some View {
        let t = AnyTransition.islandGlyph(swap: model.contentSwap, toward: .leading, reduce: reduce)
        return HStack(spacing: 10) {
            IslandMicBadge(mode: model.mode, formula: state.ocrFormula)
            if phase == .recording && model.mode == .ocr {
                IslandSelectHint(formula: state.ocrFormula).transition(t)
            } else {
                if phase == .recording { IslandRecDot().transition(t) }
                IslandTimerText(start: model.recordingStart, frozen: model.frozenElapsed)
                if phase == .recording { wave.transition(t) }
            }
            if phase == .processing { ring.transition(t) }
            if phase == .processing, let since = model.slowSince {
                IslandSlowSeconds(since: since).transition(t)
            }
            if phase == .processing, model.slowHint {
                Text(L("Dauert länger")).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75)).fixedSize().transition(t)
                Text(L("%@ bricht ab", HotkeyFormat.display(state.hotkeys["dictate"] ?? "ctrl+shift")))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize().transition(t)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: IslandMetrics.capsuleHeight)
    }

    /// the live transcript hanging under the capsule (the capsule itself keeps mic, dot, timer
    /// and waveform)
    private var liveCardContent: some View {
        IslandLiveTextView(text: state.partialText, brightWords: model.brightWords, mode: model.mode,
                           processing: phase == .processing, overflowing: liveLines > IslandMetrics.liveMaxLines,
                           still: model.stillTime, reduceMotion: reduce)
            .padding(.top, 11)
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
            .frame(width: IslandMetrics.liveWidth, alignment: .leading)
    }

    private func doneCard(_ d: DoneInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                IslandCheckBadge(mode: model.mode)
                (Text(IslandCopy.title(d, mode: model.mode))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                 + Text(IslandCopy.meta(d))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if d.toClipboard {
                    IslandKeyCap(label: "⌘V")
                } else {
                    Text(IslandCopy.seconds(d.seconds))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(height: 24)
            IslandDoneText(done: d, mode: model.mode, previewLines: live ? 5 : 1, keepLines: live,
                           expanded: expanded, still: model.stillTime != nil, reduce: reduce,
                           stillCopied: model.stillCopied)
                .padding(.leading, 28)
        }
        .padding(.top, 9)
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.bottom, 13)
        .frame(width: cardWidth, alignment: .leading)
        // on hover the card widens on the width spring: badge, title and seconds ride along
        .animation(layoutMode ? nil : IslandMotion.width(growing: growing), value: expanded)
    }

    private var errorCard: some View {
        HStack(spacing: 8) {
            if model.noticeOK { IslandCheckBadge(mode: model.mode) } else { IslandErrorBadge() }
            IslandErrorBody(message: errorText)
        }
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .frame(width: errorWidth, alignment: .leading)
    }
}


// MARK: - Screen context on the confirmation (KONTEXT-PLAN.md)

/// "Verwendeter Kontext": sources, counts and names of this take, never the text itself.
struct IslandContextSection: View {
    let info: ContextInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.used ? L("Verwendeter Kontext") : IslandCopy.contextLabel(info.label))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            ForEach(Array(info.rows.prefix(4).enumerated()), id: \.offset) { _, raw in
                let row = IslandCopy.contextRow(raw)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 96, alignment: .leading)
                    Text(row.value)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11.5))
            }
            if let w = info.warning {
                Text(L(w))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0xFFD27A))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if info.used {
                Text(L("Nur für dieses Diktat genutzt und schon verworfen."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "In Mail ausschalten": sets this app to level 0 (contextApps) and tells Python.
struct IslandContextOffButton: View {
    let app: String
    let bundle: String
    var still = false
    @State private var done = false

    var body: some View {
        Button {
            guard !done, !still, let state = IPC.state else { return }
            state.settings.contextApps[bundle] = 0
            state.commitSettings()
            done = true
        } label: {
            Text(done ? L("Ausgeschaltet") : L("In %@ ausschalten", app))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(done ? 0.5 : 0.9))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.14)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Bildschirmkontext in %@ ausschalten", app))
    }
}
