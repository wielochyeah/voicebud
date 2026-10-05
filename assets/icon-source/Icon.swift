// VoiceBud app icon, concept "Insel".
//
// The top of a MacBook screen, close up: a black bezel strip along the top of the
// squircle, the notch island hanging from it with concave ears, the violet 7-bar
// waveform inside the island, and the light pearl "screen" below. Apple macOS grid:
// 1024 canvas, 824 body, continuous corners r = 185, soft drop shadow.
//
// Build:
//   SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
//   swiftc -sdk $SDKROOT -swift-version 5 -O -target arm64-apple-macosx15.0 Icon.swift -o icon
// Run:
//   ./icon master <out.png> [px]          large master (default 1024)
//   ./icon small  <out.png> <16|32|64>    pixel-snapped small-size master
//   ./icon preview <out.png>              master at 640 px on a light ground
//   ./icon smallcheck <out.png> [px…]     downscaled master vs. small master, magnified
//   ./icon dock <out.png> <png|icns|insel>…   Dock context at 128 / 64 / 32 px

import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

// MARK: - Colour

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255, a])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

// MARK: - Parameters (1024-canvas units, y down)

struct Params {
    // bezel strip: from the body's top edge (y = 100) down to y = 100 + band
    var band: CGFloat = 170
    var shoulderR: CGFloat = 70      // rounded top corners of the screen
    // notch island, hanging from the top edge; its visible part starts at the bezel line
    var islandW: CGFloat = 420
    var islandH: CGFloat = 420       // measured from the body's top edge
    var islandR: CGFloat = 120
    var earR: CGFloat = 56           // concave ears where the island meets the bezel line
    // waveform: 7 centre-weighted bars, VoiceBud's dictation gradient
    var bars: [CGFloat] = [0.28, 0.52, 0.80, 1.0, 0.82, 0.55, 0.30]
    var barW: CGFloat = 28
    var barWidths: [CGFloat]? = nil
    var barGap: CGFloat = 22
    var barMax: CGFloat = 170
    var barMin: CGFloat = 40
    var barRadius: CGFloat? = nil    // default: fully rounded
    var waveDY: CGFloat = -6         // offset from the centre of the visible island
    var glow: CGFloat = 0.40
    // surface and finish
    var pearl: [(CGFloat, UInt32)] = [(0, 0xFFFFFF), (0.4, 0xF4F4F8), (1, 0xDADCE4)]
    var iridescence: CGFloat = 0.6   // faint lilac / mint sheen: the two mode colours as reflections
    var violetPool: CGFloat = 0.24   // the waveform's light spilling onto the screen
    var islandShadow: CGFloat = 0.22
    var glass: CGFloat = 1           // gloss on the bezel + light rim, keeps it apart from dark docks
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185

func bodyPath() -> CGPath {
    RoundedRectangle(cornerRadius: bodyRadius, style: .continuous).path(in: body).cgPath
}

// MARK: - Geometry

// Top boundary of the body at x (bisection on the continuous-corner path).
func edgeY(_ x: CGFloat) -> CGFloat {
    let bp = bodyPath()
    var lo: CGFloat = body.minY - 1, hi: CGFloat = body.midY
    if !bp.contains(CGPoint(x: x, y: hi)) { return hi }
    for _ in 0..<40 {
        let m = (lo + hi) / 2
        if bp.contains(CGPoint(x: x, y: m)) { hi = m } else { lo = m }
    }
    return hi
}

// Concave ear between a vertical island side and the bezel line (or the body's real,
// possibly curved, top edge). The fillet circle touches the side and is tangent to the
// edge, so the ear runs out cleanly. dir = -1: ear left of the side, +1: right of it.
func ear(side: CGFloat, r: CGFloat, dir: CGFloat, band: CGFloat) -> CGPath {
    let cx = side + dir * r
    let xs = stride(from: cx - 2 * r, through: cx + 2 * r, by: 0.5)
        .map { CGPoint(x: $0, y: max(edgeY($0), body.minY + band)) }
    func minDist(_ cy: CGFloat) -> (CGFloat, CGFloat) {
        var best = CGFloat.greatestFiniteMagnitude, bx: CGFloat = cx
        for p in xs { let d = hypot(p.x - cx, p.y - cy); if d < best { best = d; bx = p.x } }
        return (best, bx)
    }
    var lo = body.minY + band, hi = body.minY + band + 4 * r
    for _ in 0..<40 {
        let m = (lo + hi) / 2
        if minDist(m).0 < r { lo = m } else { hi = m }
    }
    let cy = hi, tx = minDist(cy).1
    let x0 = min(tx, side), x1 = max(tx, side)
    let rect = CGPath(rect: CGRect(x: x0, y: body.minY - 60, width: x1 - x0, height: cy - body.minY + 60), transform: nil)
    let circle = CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
    return rect.subtracting(circle)
}

// Where the bezel line runs into the body's side the screen would end in a sharp
// corner. Round it: a circle tangent to the bezel line and to the body outline; the
// wedge outside the circle joins the bezel. dir = -1: left corner, +1: right corner.
func cornerFillet(band: CGFloat, r: CGFloat, dir: CGFloat) -> CGPath {
    let yb = body.minY + band
    let pts = stride(from: body.minX, through: body.midX, by: 0.25).map { x -> CGPoint in
        let xx = dir < 0 ? x : 1024 - x
        return CGPoint(x: xx, y: edgeY(xx))
    }
    func minDist(_ c: CGPoint) -> (CGFloat, CGPoint) {
        var best = CGFloat.greatestFiniteMagnitude, bp = c
        for q in pts { let d = hypot(q.x - c.x, q.y - c.y); if d < best { best = d; bp = q } }
        return (best, bp)
    }
    var lo: CGFloat = 0, hi: CGFloat = 400
    for _ in 0..<40 {
        let m = (lo + hi) / 2
        let c = CGPoint(x: dir < 0 ? body.minX + m : body.maxX - m, y: yb + r)
        if minDist(c).0 < r { lo = m } else { hi = m }
    }
    let c = CGPoint(x: dir < 0 ? body.minX + hi : body.maxX - hi, y: yb + r)
    let t = minDist(c).1
    let x0 = min(t.x, c.x), x1 = max(t.x, c.x)
    let rect = CGPath(rect: CGRect(x: x0, y: 0, width: x1 - x0, height: t.y), transform: nil)
    let circle = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
    return rect.subtracting(circle)
}

// Bezel strip + notch island + ears + rounded screen corners, as one black shape.
func islandPath(_ p: Params) -> CGPath {
    let cx = body.midX
    let xL = cx - p.islandW / 2, xR = cx + p.islandW / 2
    let block = UnevenRoundedRectangle(
        topLeadingRadius: 0, bottomLeadingRadius: p.islandR,
        bottomTrailingRadius: p.islandR, topTrailingRadius: 0, style: .continuous)
        .path(in: CGRect(x: xL, y: body.minY - 60, width: p.islandW, height: p.islandH + 60)).cgPath
    var shape = block.union(ear(side: xL, r: p.earR, dir: -1, band: p.band))
                     .union(ear(side: xR, r: p.earR, dir: 1, band: p.band))
    if p.band > 0 {
        shape = shape.union(CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: body.minY + p.band), transform: nil))
        if p.shoulderR > 0 {
            shape = shape.union(cornerFillet(band: p.band, r: p.shoulderR, dir: -1))
                         .union(cornerFillet(band: p.band, r: p.shoulderR, dir: 1))
        }
    }
    return shape.intersection(bodyPath())
}

func barRects(_ p: Params) -> [CGRect] {
    let n = p.bars.count
    let widths = p.barWidths ?? Array(repeating: p.barW, count: n)
    let total = widths.reduce(0, +) + CGFloat(n - 1) * p.barGap
    let cy = body.minY + (p.band + p.islandH) / 2 + p.waveDY
    var x = body.midX - total / 2
    var out: [CGRect] = []
    for (i, v) in p.bars.enumerated() {
        let h = max(p.barMin, v * p.barMax)
        out.append(CGRect(x: x, y: cy - h / 2, width: widths[i], height: h))
        x += widths[i] + p.barGap
    }
    return out
}

// MARK: - Drawing. `s` = device pixels per unit (shadow blur is not scaled by the CTM).

func strokeInside(_ ctx: CGContext, _ path: CGPath, width: CGFloat,
                  _ g: CGGradient, from a: CGPoint, to b: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.addPath(path); ctx.setLineWidth(width * 2)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext, _ p: Params, s: CGFloat) {
    let bp = bodyPath()

    // 1. drop shadow (soft and wide, plus a tight contact shadow)
    for (dy, blur, a) in [(10.0, 26.0, 0.30), (1.5, 3.0, 0.18)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * s), blur: blur * s, color: rgb(0x000000, a))
        ctx.addPath(bp); ctx.setFillColor(rgb(0xE6E7EB)); ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(bp); ctx.clip()

    // 2. pearl screen
    ctx.drawLinearGradient(gradient(p.pearl.map { ($0.0, rgb($0.1)) }),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFFFFF, 0.55)), (1, rgb(0xFFFFFF, 0))]),
                           startCenter: CGPoint(x: 512, y: 330), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 330), endRadius: 470, options: [])
    ctx.drawRadialGradient(gradient([(0, rgb(0x9AA0B4, 0)), (0.7, rgb(0x9AA0B4, 0)), (1, rgb(0x8A90A6, 0.16))]),
                           startCenter: CGPoint(x: 512, y: 420), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 420), endRadius: 720, options: [])
    if p.iridescence > 0 {
        ctx.drawRadialGradient(gradient([(0, rgb(0xC9B8F6, 0.55 * p.iridescence)), (1, rgb(0xC9B8F6, 0))]),
                               startCenter: CGPoint(x: 170, y: 900), startRadius: 0,
                               endCenter: CGPoint(x: 170, y: 900), endRadius: 560, options: [])
        ctx.drawRadialGradient(gradient([(0, rgb(0xB4EBE2, 0.45 * p.iridescence)), (1, rgb(0xB4EBE2, 0))]),
                               startCenter: CGPoint(x: 930, y: 700), startRadius: 0,
                               endCenter: CGPoint(x: 930, y: 700), endRadius: 470, options: [])
    }

    let ip = islandPath(p)
    let islandBottom = body.minY + p.islandH

    // 3. violet light below the island
    if p.violetPool > 0 {
        ctx.saveGState()
        ctx.translateBy(x: 512, y: islandBottom + 10 - 230 * 0.25)
        ctx.scaleBy(x: 1.55, y: 1)
        ctx.drawRadialGradient(gradient([(0, rgb(0xA98AF7, p.violetPool)), (0.45, rgb(0xA98AF7, p.violetPool * 0.45)),
                                         (1, rgb(0xA98AF7, 0))]),
                               startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 230, options: [])
        ctx.restoreGState()
    }

    // 4. inner edge of the body: light at the top, a whisper of thickness at the bottom
    strokeInside(ctx, bp, width: 5,
                 gradient([(0, rgb(0xFFFFFF, 0.95)), (0.22, rgb(0xFFFFFF, 0.25)), (0.5, rgb(0xFFFFFF, 0))]),
                 from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    strokeInside(ctx, bp, width: 3,
                 gradient([(0.6, rgb(0x5A6075, 0)), (1, rgb(0x5A6075, 0.22))]),
                 from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))

    // 5. bezel + island: soft shadow onto the screen, then pure black
    if p.islandShadow > 0 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 38 * s, color: rgb(0x1A1830, p.islandShadow))
        ctx.addPath(ip); ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.addPath(ip); ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
    // hairline of light along the island's lower curve: glass, not a hole
    strokeInside(ctx, ip, width: 2.5,
                 gradient([(0, rgb(0xFFFFFF, 0)), (0.55, rgb(0xFFFFFF, 0)), (1, rgb(0xFFFFFF, 0.13))]),
                 from: CGPoint(x: 512, y: body.minY), to: CGPoint(x: 512, y: islandBottom))

    // 6. waveform: restrained glow, then the bars with one shared vertical gradient
    let rects = barRects(p)
    let barsPath = CGMutablePath()
    for r in rects {
        barsPath.addPath(RoundedRectangle(cornerRadius: p.barRadius ?? min(r.width, r.height) / 2,
                                          style: .circular).path(in: r).cgPath)
    }
    let top = rects.map { $0.minY }.min()!, bottom = rects.map { $0.maxY }.max()!
    if p.glow > 0 {
        ctx.saveGState()
        ctx.addPath(ip); ctx.clip()
        ctx.setShadow(offset: .zero, blur: 34 * s, color: rgb(0x8F6CF2, p.glow))
        ctx.addPath(barsPath); ctx.setFillColor(rgb(0x9F82F4)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(barsPath); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xE4DAFF)), (0.5, rgb(0xB89EFA)), (1, rgb(0x8F6CF2))]),
                           start: CGPoint(x: 512, y: top), end: CGPoint(x: 512, y: bottom), options: [])
    ctx.restoreGState()

    // 7. black glass: a faint gloss falling off the top of the bezel (it fades out above
    //    the bezel line, so the notch stays pure black) and a light rim along the outline
    if p.glass > 0 {
        ctx.saveGState()
        ctx.addPath(ip); ctx.clip()
        ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0.10 * p.glass)), (1, rgb(0xFFFFFF, 0))]),
                               start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.minY + p.band * 0.85),
                               options: [])
        ctx.restoreGState()
        strokeInside(ctx, bp, width: 3,
                     gradient([(0, rgb(0xFFFFFF, 0.34 * p.glass)), (0.10, rgb(0xFFFFFF, 0.16 * p.glass)), (0.2, rgb(0xFFFFFF, 0))]),
                     from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    }

    ctx.restoreGState() // body clip

    // 8. outer hairline so the light body holds its edge on white backgrounds
    ctx.saveGState()
    ctx.addPath(bp); ctx.clip()
    ctx.addPath(bp); ctx.setLineWidth(2); ctx.setStrokeColor(rgb(0x000000, 0.10)); ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Small-size masters: same picture, every edge on the target pixel grid

func smallParams(_ px: Int) -> Params {
    var p = Params()
    let u = 1024 / CGFloat(px)   // one target pixel in canvas units
    func centreWave(at cy: CGFloat) { p.waveDY = cy - body.minY - (p.band + p.islandH) / 2 }
    if px <= 16 {
        // bezel line at 4 px, notch 4..12 px wide down to 10 px; three bars 1-2-1 px wide
        p.band = 4 * u - body.minY; p.islandW = 8 * u; p.islandH = 10 * u - body.minY
        p.islandR = 2 * u; p.earR = 1 * u; p.shoulderR = 1.2 * u
        p.bars = [0.5, 1.0, 0.5]; p.barWidths = [1 * u, 2 * u, 1 * u]; p.barGap = 1 * u
        p.barMax = 4 * u; p.barMin = 0; p.barRadius = 0.5 * u
        centreWave(at: 7 * u)
        p.glow = 0; p.islandShadow = 0.12; p.violetPool = 0.16; p.glass = 1.4
    } else if px <= 32 {
        // bezel line at 8 px, notch 8..24 px wide down to 17 px; three 2 px bars, 2 px apart
        p.band = 8 * u - body.minY; p.islandW = 16 * u; p.islandH = 17 * u - body.minY
        p.islandR = 4 * u; p.earR = 1.5 * u; p.shoulderR = 2 * u
        p.bars = [0.667, 1.0, 0.667]; p.barW = 2 * u; p.barGap = 2 * u
        p.barMax = 6 * u; p.barMin = 0
        centreWave(at: 12 * u)
        p.glow = 0.22; p.islandShadow = 0.16; p.glass = 1.2
    } else {
        // 64 px: bezel line at 17 px, notch 19..45 px down to 33 px; seven 2 px bars, 1 px apart
        p.band = 17 * u - body.minY; p.islandW = 26 * u; p.islandH = 33 * u - body.minY
        p.islandR = 7.5 * u; p.earR = 3.5 * u; p.shoulderR = 4.5 * u
        p.bars = [0.4, 0.6, 0.8, 1.0, 0.8, 0.6, 0.4]; p.barW = 2 * u; p.barGap = 1 * u
        p.barMax = 10 * u; p.barMin = 0
        centreWave(at: 25 * u)
        p.glow = 0.30
    }
    return p
}

// MARK: - Output

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

func renderIcon(_ p: Params, px: Int) -> CGImage {
    let ctx = makeContext(px, px)
    let s = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: s, y: -s)
    drawIcon(ctx, p, s: s)
    return ctx.makeImage()!
}

func savePNG(_ img: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

func downscale(_ img: CGImage, _ px: Int) -> CGImage {
    let ctx = makeContext(px, px)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

func loadImage(_ path: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

// .icns: the smallest representation at least `s` px wide
func pickRep(_ path: String, _ s: Int) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let all = (0..<CGImageSourceGetCount(src)).compactMap { CGImageSourceCreateImageAtIndex(src, $0, nil) }
    return all.filter { $0.width >= s }.min { $0.width < $1.width } ?? all.max { $0.width < $1.width }!
}

// MARK: - Commands

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "master":
    savePNG(renderIcon(Params(), px: args.count > 3 ? Int(args[3])! : 1024), args[2])

case "small":
    let px = Int(args[3])!
    savePNG(renderIcon(smallParams(px), px: px), args[2])

case "preview":
    let ctx = makeContext(660, 660)
    ctx.setFillColor(rgb(0xE9E9EC)); ctx.fill(CGRect(x: 0, y: 0, width: 660, height: 660))
    ctx.draw(renderIcon(Params(), px: 1024), in: CGRect(x: 10, y: 10, width: 640, height: 640))
    savePNG(ctx.makeImage()!, args[2])

case "smallcheck":
    let big = renderIcon(Params(), px: 1024)
    let sizes = args.count > 3 ? args[3...].map { Int($0)! } : [32, 16]
    let ctx = makeContext(1500, 380 * sizes.count)
    for (row, px) in sizes.enumerated() {
        let mag = CGFloat(320 / px)
        let y = CGFloat(380 * (sizes.count - 1 - row) + 20)
        let imgs = [downscale(big, px), renderIcon(smallParams(px), px: px)]
        for (k, dark) in [false, true].enumerated() {
            let x0 = CGFloat(k * 750)
            ctx.setFillColor(rgb(dark ? 0x26262A : 0xEDEDF0))
            ctx.fill(CGRect(x: x0, y: y - 20, width: 750, height: 380))
            for (j, img) in imgs.enumerated() {
                let xx = x0 + 20 + CGFloat(j) * 360
                ctx.interpolationQuality = .none
                ctx.draw(img, in: CGRect(x: xx, y: y, width: CGFloat(px) * mag, height: CGFloat(px) * mag))
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: xx + CGFloat(px) * mag + 6, y: y, width: CGFloat(px), height: CGFloat(px)))
            }
        }
    }
    savePNG(ctx.makeImage()!, args[2])

case "dock":
    let names = Array(args[3...])
    let sizes: [CGFloat] = [128, 64, 32], rowH: [CGFloat] = [150, 80, 46]
    let W = CGFloat(names.count) * 140 + 20, H = 2 * rowH.reduce(0, +)
    let ctx = makeContext(Int(W), Int(H))
    var y = H
    for dark in [false, true] {
        for (k, s) in sizes.enumerated() {
            y -= rowH[k]
            ctx.setFillColor(rgb(dark ? 0x2B2B30 : 0xEDEDF0)); ctx.fill(CGRect(x: 0, y: y, width: W, height: rowH[k]))
            for (i, n) in names.enumerated() {
                let img: CGImage
                if n.hasSuffix(".icns") {
                    let rep = pickRep(n, Int(s)); img = rep.width == Int(s) ? rep : downscale(rep, Int(s))
                } else if n.hasSuffix(".png") {
                    img = downscale(loadImage(n), Int(s))
                } else {
                    img = s >= 128 ? downscale(renderIcon(Params(), px: 1024), 128) : renderIcon(smallParams(Int(s)), px: Int(s))
                }
                ctx.draw(img, in: CGRect(x: 20 + CGFloat(i) * 140 + (128 - s) / 2, y: y + (rowH[k] - s) / 2, width: s, height: s))
            }
        }
    }
    savePNG(ctx.makeImage()!, args[2])

default:
    print("usage: icon master|small|preview|smallcheck|dock …")
}
