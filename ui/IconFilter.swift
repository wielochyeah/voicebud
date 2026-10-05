// Texterkennung: icon glyphs Vision reads as characters ("*", "G", "目", "凸", "{ğ"; 04.10., Nils: "nervt")
// are dropped. Decided on the picture, not on the character (confidence does not tell them apart):
// the ink of a line's first run is coloured in front of neutral text, or taller and wider than a
// capital and set off from the word by a gap; a lone glyph is CJK in a Latin picture, coloured, or
// far taller than the text. Enumerators (1., a), (2), ii.) and plain numbers always stay.
import AppKit
import Vision

struct InkRun { var x0: Int; var x1: Int; var y0: Int; var y1: Int; var chroma: Double }

/// ink runs (letters closer than a quarter line height are one run) inside a normalised Vision box
func inkRuns(_ img: CGImage, _ box: CGRect) -> (runs: [InkRun], lineH: Int) {
    let W = CGFloat(img.width), H = CGFloat(img.height)
    let px = CGRect(x: box.minX * W, y: (1 - box.maxY) * H, width: box.width * W, height: box.height * H).integral
        .intersection(CGRect(x: 0, y: 0, width: W, height: H))
    guard px.width >= 3, px.height >= 3, let crop = img.cropping(to: px) else { return ([], 0) }
    let w = crop.width, h = crop.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ([], 0) }
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2])) }
    var hist = [Int](repeating: 0, count: 64)
    var border: [(Int, Int, Int)] = []
    for x in 0..<w { border.append(rgb(x, 0)); border.append(rgb(x, h - 1)) }
    for y in 0..<h { border.append(rgb(0, y)); border.append(rgb(w - 1, y)) }
    for c in border { hist[(c.0 + c.1 + c.2) / 12] += 1 }
    let bin = hist.indices.max { hist[$0] < hist[$1] }!
    let bgs = border.filter { ($0.0 + $0.1 + $0.2) / 12 == bin }
    let bg = (bgs.map(\.0).reduce(0, +) / bgs.count, bgs.map(\.1).reduce(0, +) / bgs.count, bgs.map(\.2).reduce(0, +) / bgs.count)
    let join = max(2, h / 4)
    var runs: [InkRun] = [], cur: InkRun?
    var last = -1000
    var cs = 0.0, cn = 0.0           // chroma of the current run
    for x in 0..<w {
        var top = -1, bot = -1, colSum = 0.0, colN = 0.0
        for y in 0..<h {
            let c = rgb(x, y)
            guard abs(c.0 - bg.0) + abs(c.1 - bg.1) + abs(c.2 - bg.2) > 150 else { continue }
            if top < 0 { top = y }
            bot = y
            colSum += Double(max(c.0, c.1, c.2) - min(c.0, c.1, c.2)); colN += 1
        }
        guard top >= 0 else { continue }
        if var r = cur, x - last <= join {
            r.x1 = x; r.y0 = min(r.y0, top); r.y1 = max(r.y1, bot); cur = r
            cs += colSum; cn += colN
        } else {
            if var r = cur { r.chroma = cn > 0 ? cs / cn : 0; runs.append(r) }
            cur = InkRun(x0: x, x1: x, y0: top, y1: bot, chroma: 0)
            cs = colSum; cn = colN
        }
        last = x
    }
    if var r = cur { r.chroma = cn > 0 ? cs / cn : 0; runs.append(r) }
    return (runs, h)
}

final class IconFilter {
    let img: CGImage
    let on: Bool
    var medWord = 1.0, textChroma = 0.0, hasCJK = false
    var cache: [CGRect: (runs: [InkRun], lineH: Int)] = [:]

    static let enumerator = try! NSRegularExpression(pattern: "^(\\(?[0-9]{1,3}[.)]|[a-zA-Z][.)]|\\([0-9a-zA-Z]{1,3}\\)|[ivxIVX]{1,5}[.)])$")
    static func isEnumerator(_ t: String) -> Bool { enumerator.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil }
    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        (0x2E80...0x9FFF).contains(u.value) || (0xAC00...0xD7AF).contains(u.value) || (0x1100...0x11FF).contains(u.value)
            || (0x3130...0x318F).contains(u.value) || (0xF900...0xFAFF).contains(u.value) || (0xFF00...0xFFEF).contains(u.value)
    }

    @available(macOS 26.0, *)
    convenience init(_ img: CGImage, doc: DocumentObservation.Container, on: Bool = true) {
        var boxes: [CGRect] = []
        var transcripts: [String] = []
        for p in doc.paragraphs { boxes += p.lines.map { $0.boundingBox.cgRect }; transcripts.append(p.transcript) }
        for t in doc.tables { for c in t.rows.flatMap({ $0 }) { boxes += c.content.text.lines.map { $0.boundingBox.cgRect } } }
        self.init(img, boxes: boxes, transcripts: transcripts, on: on)
    }

    init(_ img: CGImage, boxes: [CGRect], transcripts: [String], on: Bool) {
        self.img = img
        self.on = on
        guard on else { return }
        let t0 = Date()
        var heights: [Int] = [], chromas: [Double] = []
        for b in boxes {
            let r = runs(b)
            for run in r.runs where run.x1 - run.x0 > 2 * (run.y1 - run.y0) { heights.append(run.y1 - run.y0); chromas.append(run.chroma) }
        }
        if !heights.isEmpty { medWord = Double(heights.sorted()[heights.count / 2]) }
        if !chromas.isEmpty { textChroma = chromas.sorted()[chromas.count / 2] }
        hasCJK = transcripts.contains { $0.unicodeScalars.filter(Self.isCJK).count >= 5 }
        OCRHelper.iconMs += Int(Date().timeIntervalSince(t0) * 1000)
    }

    func runs(_ b: CGRect) -> (runs: [InkRun], lineH: Int) {
        if let c = cache[b] { return c }
        let r = inkRuns(img, b)
        cache[b] = r
        return r
    }

    /// an icon glyph in front of the words of a line
    func lead(_ tok: String, _ box: CGRect) -> Bool {
        guard tok.count <= 2, !Self.isEnumerator(tok) else { return false }
        let (rs, lh) = runs(box)
        guard rs.count >= 2, lh > 0 else { return false }
        let r0 = rs[0]
        let w0 = Double(r0.x1 - r0.x0) / medWord, h0 = Double(r0.y1 - r0.y0) / medWord
        guard w0 < 3 else { return false }                                       // first run is the word itself
        let rest = rs.dropFirst().map(\.chroma).reduce(0, +) / Double(rs.count - 1)
        if r0.chroma >= 60 && rest <= 30 { return true }
        let gap = Double(rs[1].x0 - r0.x1) / Double(lh)
        return h0 >= 1.1 && w0 >= 1.1 && gap >= 0.45
    }

    /// a line that is nothing but an icon glyph
    func alone(_ tok: String, _ box: CGRect) -> Bool {
        let scalars = tok.unicodeScalars
        let cjk = scalars.filter(Self.isCJK).count
        if cjk > 0 && cjk >= scalars.count - 1 && scalars.count <= 4 && !hasCJK { return true }
        guard tok.count <= 2, !Self.isEnumerator(tok), !tok.allSatisfy(\.isNumber) else { return false }
        let (rs, _) = runs(box)
        guard let f = rs.first else { return false }
        let u = rs.dropFirst().reduce(f) { InkRun(x0: min($0.x0, $1.x0), x1: max($0.x1, $1.x1), y0: min($0.y0, $1.y0), y1: max($0.y1, $1.y1), chroma: max($0.chroma, $1.chroma)) }
        if u.chroma >= 60 && textChroma <= 30 { return true }
        return Double(u.y1 - u.y0) / medWord >= 1.8
    }

    @available(macOS 26.0, *)
    func clean(_ t: DocumentObservation.Container.Text) -> String {
        let s = t.transcript
        guard on else { return s }
        let t0 = Date()
        defer { OCRHelper.iconMs += Int(Date().timeIntervalSince(t0) * 1000) }
        var cuts: [Range<String.Index>] = []
        var cursor = s.startIndex
        for l in t.lines {
            guard let ls = l.topCandidates(1).first?.string, let r = s.range(of: ls, range: cursor..<s.endIndex) else { continue }
            cursor = r.upperBound
            if let cut = cutRange(ls, l.boundingBox.cgRect) {
                let lo = s.index(r.lowerBound, offsetBy: ls.distance(from: ls.startIndex, to: cut.lowerBound))
                let hi = s.index(r.lowerBound, offsetBy: ls.distance(from: ls.startIndex, to: cut.upperBound))
                cuts.append(lo..<hi)
            }
        }
        var out = s
        for c in cuts.reversed() { out.removeSubrange(c) }
        return out
    }

    /// what to cut from one recognised line: the whole line (an icon alone) or its first token
    func cutRange(_ ls: String, _ box: CGRect) -> Range<String.Index>? {
        let trimmed = ls.drop(while: \.isWhitespace)
        guard let firstEnd = trimmed.firstIndex(where: \.isWhitespace) else {
            return alone(String(trimmed), box) ? ls.startIndex..<ls.endIndex : nil
        }
        let tok = String(trimmed[trimmed.startIndex..<firstEnd])
        guard lead(tok, box) else { return nil }
        let after = ls[firstEnd...].firstIndex(where: { !$0.isWhitespace }) ?? ls.endIndex
        return trimmed.startIndex..<after
    }

    /// the classic recogniser's lines (single-line path, macOS 15)
    static func cleanLines(_ lines: [OCRHelper.Line], _ img: CGImage) -> [OCRHelper.Line] {
        guard !lines.isEmpty else { return lines }
        let f = IconFilter(img, boxes: lines.map(\.box), transcripts: lines.map(\.text), on: true)
        let t0 = Date()
        defer { OCRHelper.iconMs += Int(Date().timeIntervalSince(t0) * 1000) }
        return lines.compactMap { l in
            guard let cut = f.cutRange(l.text, l.box) else { return l }
            var t = l.text
            t.removeSubrange(cut)
            return t.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (t, l.box)
        }
    }
}
