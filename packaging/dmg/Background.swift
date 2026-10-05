// Renders the DMG window backgrounds (640 x 400 pt, 1x and 2x) and a preview with the icons where
// Finder will put them. Usage: Background <out dir> <app icon .icns>
import AppKit
import SwiftUI

let W: CGFloat = 640, H: CGFloat = 400
let iconY: CGFloat = 158, appX: CGFloat = 170, appsX: CGFloat = 470, iconSize: CGFloat = 112
let violet = Color(red: 0.72, green: 0.62, blue: 0.98), violetDeep = Color(red: 0.56, green: 0.42, blue: 0.95)
let ink = Color(red: 0.12, green: 0.11, blue: 0.16), prose = Color(red: 0.42, green: 0.40, blue: 0.50)

struct Island: Shape {            // the closed notch island with concave ears, as in the app
    func path(in r: CGRect) -> Path {
        let ear: CGFloat = 10, bottom: CGFloat = 18
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear, y: r.minY + ear), control: CGPoint(x: r.minX + ear, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + ear, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear + bottom, y: r.maxY), control: CGPoint(x: r.minX + ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - ear, y: r.maxY - bottom), control: CGPoint(x: r.maxX - ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear, y: r.minY + ear))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - ear, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct Wave: View {               // the calm 7-bar waveform of the island
    var heights: [CGFloat] = [0.32, 0.55, 0.8, 1.0, 0.8, 0.55, 0.32]
    var bar: CGFloat = 4, gap: CGFloat = 4, height: CGFloat = 20
    var body: some View {
        HStack(alignment: .center, spacing: gap) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                Capsule().fill(LinearGradient(colors: [violet, violetDeep], startPoint: .top, endPoint: .bottom))
                    .frame(width: bar, height: max(bar, height * h))
            }
        }
        .shadow(color: violet.opacity(0.7), radius: 5)
    }
}

struct Arrow: View {
    var body: some View {
        Canvas { ctx, size in
            let y = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width - 4, y: y))
            var head = Path()
            head.move(to: CGPoint(x: size.width - 13, y: y - 9))
            head.addLine(to: CGPoint(x: size.width - 3, y: y))
            head.addLine(to: CGPoint(x: size.width - 13, y: y + 9))
            let style = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [0.1, 8])
            ctx.stroke(line, with: .linearGradient(Gradient(colors: [violet.opacity(0.35), violetDeep]),
                                                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)), style: style)
            ctx.stroke(head, with: .color(violetDeep), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 130, height: 24)
    }
}

/// two lines, nothing more: the drag (also shown by the arrow) and the one step people get stuck on
struct Hint: View {
    var body: some View {
        VStack(spacing: 7) {
            Text("Zieh VoiceBud auf den Ordner Programme.")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(ink.opacity(0.85))
            HStack(spacing: 6) {
                Image(systemName: "lock.open.fill").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(violetDeep)
                (Text("Beim ersten Öffnen: Systemeinstellungen, Datenschutz & Sicherheit, ") +
                 Text("„Trotzdem öffnen“").bold())
                    .font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.75)))
            .overlay(Capsule().strokeBorder(violet.opacity(0.35), lineWidth: 1))
        }
    }
}

/// A: the island at the top, a soft violet light behind the icons
struct VariantInsel: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.985, green: 0.98, blue: 1.0), Color(red: 0.93, green: 0.91, blue: 0.99)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [violet.opacity(0.28), .clear], center: UnitPoint(x: 0.5, y: iconY / H),
                           startRadius: 10, endRadius: 300)
            Island().fill(Color.black)
                .frame(width: 236, height: 40)
                .overlay(Wave(height: 18).padding(.top, 2))
                .position(x: W / 2, y: 20)
            Arrow().position(x: W / 2, y: iconY)
            Hint().position(x: W / 2, y: 330)
        }
        .frame(width: W, height: H)
    }
}

/// B: quieter, one large waveform across the window, no island
struct VariantWelle: View {
    var body: some View {
        ZStack {
            Color(red: 0.99, green: 0.985, blue: 0.975)
            Wave(heights: [0.18, 0.3, 0.46, 0.66, 0.84, 1.0, 0.84, 0.66, 0.46, 0.3, 0.18], bar: 14, gap: 16, height: 230)
                .opacity(0.16)
                .position(x: W / 2, y: iconY)
            VStack(spacing: 3) {
                Text("VoiceBud").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(ink)
                Text("Diktieren, lokal auf deinem Mac").font(.system(size: 12.5)).foregroundStyle(prose)
            }
            .position(x: W / 2, y: 62)
            Arrow().position(x: W / 2, y: iconY)
            Hint().position(x: W / 2, y: 350)
        }
        .frame(width: W, height: H)
    }
}

@MainActor func write<V: View>(_ view: V, scale: CGFloat, to url: URL) {
    let r = ImageRenderer(content: view)
    r.scale = scale
    guard let cg = r.cgImage else { return }
    let rep = NSBitmapImageRep(cgImage: cg)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

/// what Finder will show: background, the two icons at their positions, labels under them
struct Preview<B: View>: View {
    let bg: B
    let appIcon: NSImage, folder: NSImage
    var body: some View {
        ZStack {
            bg
            icon(appIcon, "VoiceBud").position(x: appX, y: iconY + 10)
            icon(folder, "Programme").position(x: appsX, y: iconY + 10)
        }
        .frame(width: W, height: H)
    }
    func icon(_ img: NSImage, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: img).resizable().frame(width: iconSize, height: iconSize)
            Text(label).font(.system(size: 13)).foregroundStyle(.black)
        }
    }
}

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1], isDirectory: true)
let appIcon = NSImage(contentsOfFile: args[2]) ?? NSImage()
let folder = NSWorkspace.shared.icon(forFile: "/Applications")
folder.size = NSSize(width: 256, height: 256)
MainActor.assumeIsolated {
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for (name, view) in [("insel", AnyView(VariantInsel())), ("welle", AnyView(VariantWelle()))] {
        write(view, scale: 1, to: out.appendingPathComponent("bg-\(name).png"))
        write(view, scale: 2, to: out.appendingPathComponent("bg-\(name)@2x.png"))
        write(Preview(bg: view, appIcon: appIcon, folder: folder), scale: 2, to: out.appendingPathComponent("preview-\(name).png"))
    }
}
