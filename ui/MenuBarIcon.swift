// Menu bar symbol (05.10., Nils): how it looks while VoiceBud records, chosen in the hub
// (Darstellung). "Schlicht" is the microphone as it always was (macOS's own orange dot shows the
// recording); "Farbe" tints it in the mode's colour, "Punkt" adds a red recording dot, "Zeit"
// turns it into a capsule with the running time. With the sound muted for the take, a crossed
// out speaker stands next to it (all but "Schlicht"). Idle, every style is the plain microphone.
import AppKit

@MainActor
final class MenuBarIcon {
    static var shared: MenuBarIcon?

    private let item: NSStatusItem
    private let state: AppState
    private var timer: Timer?
    private var appearance: NSKeyValueObservation?

    static let plain: NSImage? = {
        let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "VoiceBud")
        image?.isTemplate = true
        return image
    }()

    init(item: NSStatusItem, state: AppState) {
        self.item = item
        self.state = state
        // the menu bar turns light or dark with the wallpaper: the drawn colours follow
        appearance = item.button?.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { MenuBarIcon.shared?.update() } }
        }
        update()
    }

    /// after every state message, a settings change and the mute switching on or off
    func update() {
        guard let button = item.button else { return }
        let style = state.settings.menuBarStyle
        let recording = state.phase == .recording && state.mode != .ocr
        if recording && style == .zeit { startTimer() } else { stopTimer() }
        guard recording, style != .schlicht else {
            if button.image !== Self.plain { button.image = Self.plain }
            item.length = NSStatusItem.squareLength
            button.toolTip = "VoiceBud"
            return
        }
        var ink = NSColor.labelColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            ink = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
        }
        let accent = Self.accent[state.mode] ?? .systemPurple
        var parts: [NSImage] = []
        switch style {
        case .farbe: parts.append(Self.symbol("mic.fill", accent))
        case .punkt: parts.append(Self.dotted(Self.symbol("mic.fill", ink)))
        case .zeit: parts.append(Self.capsule(accent, Self.elapsed(since: state.recordingStarted)))
        case .schlicht: break
        }
        if OutputMute.isMuted { parts.append(Self.symbol("speaker.slash.fill", ink)) }
        // one symbol alone (Farbe, Punkt) sits exactly where the plain microphone sits: the image
        // itself with the symbol's alignment, in the square item (05.10.: a redrawn copy in a
        // variable item stood a hair off, Nils)
        if parts.count == 1 && style != .zeit {
            button.image = parts[0]
            item.length = NSStatusItem.squareLength
        } else {
            button.image = Self.row(parts)
            item.length = NSStatusItem.variableLength
        }
        button.toolTip = OutputMute.isMuted ? L("VoiceBud nimmt auf, Ton stumm") : L("VoiceBud nimmt auf")
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { MenuBarIcon.shared?.update() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: drawing

    /// the modes' deeper tones (the island's pastels are made for black): violet, teal, amber
    static let accent: [Mode: NSColor] = [
        .dictate: NSColor(srgbHex: 0x8F6CF2), .prompt: NSColor(srgbHex: 0x2FBFAA),
        .command: NSColor(srgbHex: 0xE89B2E), .ocr: NSColor(srgbHex: 0x3E92F0),
    ]

    static func symbol(_ name: String, _ color: NSColor, size: CGFloat? = nil) -> NSImage {
        var config = NSImage.SymbolConfiguration(paletteColors: [color])
        if let size { config = config.applying(.init(pointSize: size, weight: .semibold)) }
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return base.withSymbolConfiguration(config) ?? base
    }

    /// the microphone with a red recording dot on its upper right, the same size and alignment
    /// as the microphone alone (so it does not move when the dot comes)
    static func dotted(_ mic: NSImage) -> NSImage {
        let d: CGFloat = 5
        let size = mic.size
        let image = NSImage(size: size, flipped: false) { _ in
            mic.draw(in: NSRect(origin: .zero, size: size))
            NSColor(srgbHex: 0xFF3B30).setFill()
            NSBezierPath(ovalIn: NSRect(x: size.width - d, y: size.height - d, width: d, height: d)).fill()
            return true
        }
        image.alignmentRect = mic.alignmentRect
        return image
    }

    /// a capsule in the mode's colour: white microphone and the running time
    static func capsule(_ color: NSColor, _ time: String) -> NSImage {
        let mic = symbol("mic.fill", .white, size: 9.5)
        let text = NSAttributedString(string: time, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white])
        let h: CGFloat = 17, pad: CGFloat = 6, gap: CGFloat = 3.5
        let w = (pad + mic.size.width + gap + text.size().width + pad + 1).rounded(.up)
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
            mic.draw(in: NSRect(x: pad, y: ((h - mic.size.height) / 2).rounded(), width: mic.size.width, height: mic.size.height))
            text.draw(at: NSPoint(x: pad + mic.size.width + gap, y: ((h - text.size().height) / 2).rounded()))
            return true
        }
    }

    /// side by side, centred on one line
    static func row(_ parts: [NSImage], gap: CGFloat = 5) -> NSImage {
        let w = parts.map(\.size.width).reduce(0, +) + gap * CGFloat(max(parts.count - 1, 0))
        let h = parts.map(\.size.height).max() ?? 16
        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            var x: CGFloat = 0
            for p in parts {
                p.draw(in: NSRect(x: x, y: ((h - p.size.height) / 2).rounded(), width: p.size.width, height: p.size.height))
                x += p.size.width + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func elapsed(since start: Date?) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start ?? Date())))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension NSColor {
    convenience init(srgbHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
