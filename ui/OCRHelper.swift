// Texterkennung helper (VoiceBudUI --ocr-helper): a short-lived child of the UI. The document
// recognition keeps ~60 MB after a run, which would break the UI's 30 MB idle budget, so it lives
// here and the process ends after 2 minutes without work.
//
// Protocol, one JSON object per line:
//   in   {"op":"warm"}                       load the models on a tiny image (while the user drags)
//        {"op":"ocr","path":"/tmp/x.png"}    recognise a screenshot
//   out  {"ok":true,"text":..,"html":..|null,"tsv":..|null,"words":n,"tables":n,"ms":n} | {"ok":false,"error":..}
import AppKit
import Foundation
import NaturalLanguage
import Vision

enum OCRHelper {
    static let idleExit: TimeInterval = 120
    static var iconMs = 0

    static func run() -> Never {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
        var last = Date()
        // idle exit: nothing to do for 2 minutes (or the UI is gone: stdin ends below)
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 5)
                if Date().timeIntervalSince(last) > idleExit { exit(0) }
            }
        }
        while let line = readLine(strippingNewline: true) {
            last = Date()
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch msg["op"] as? String {
            case "warm":
                warm()
                reply(["ok": true, "warm": true])
            case "ocr":
                let t = Date()
                guard let path = msg["path"] as? String, let img = load(path) else {
                    reply(["ok": false, "error": "image"])
                    continue
                }
                iconMs = 0
                let result = recognise(trimCutLines(img), keepLines: msg["lines"] as? Bool ?? false)
                var out: [String: Any] = ["ok": true, "text": result.text, "tsv": result.tsv ?? NSNull(),
                                          "words": result.words, "tables": result.tables,
                                          "ms": Int(Date().timeIntervalSince(t) * 1000),
                                          "vision_ms": lastSplit.vision, "repair_ms": lastSplit.repair, "icon_ms": iconMs]
                out["html"] = result.html ?? NSNull()
                reply(out)
            default:
                continue
            }
            last = Date()
        }
        exit(0)
    }

    static func reply(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    static func load(_ path: String) -> CGImage? {
        NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: cut lines

    /// A selection whose top or bottom edge runs through a line of text: that line is left out.
    /// Its half letters read as garbage, and Vision even joined one with the full line below it
    /// (05.10., Nils: "ForaleModus jet s auspreieren auf ist unverändert"; measured: cuts through
    /// the upper two thirds of a line give "instan an de Leerla", through the descenders "D•unali").
    /// A band of ink rows touching the edge counts as cut only when it is clearly lower than the
    /// full lines of the same picture AND its edge row is dense with ink (strokes cut through):
    /// an intact line that merely touches the edge has only letter tips there, and a whole line
    /// without ascenders ("nur was neu ist") is low too but must stay.
    static func trimCutLines(_ img: CGImage) -> CGImage {
        let w = img.width, h = img.height
        guard w >= 8, h >= 24 else { return img }
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))      // row 0 = top of the picture
        // the background: the most common grey (light or dark mode alike)
        var hist = [Int](repeating: 0, count: 32)
        for i in stride(from: 0, to: gray.count, by: 7) { hist[Int(gray[i]) >> 3] += 1 }
        let bg = (hist.indices.max { hist[$0] < hist[$1] } ?? 31) * 8 + 4
        // (every other column on big pictures: a full Retina screen in 7 ms instead of 14)
        let step = w * h > 2_000_000 ? 2 : 1
        let blank = max(1, w / step / 500)
        var count = [Int](repeating: 0, count: h)
        for y in 0..<h {
            let row = y * w
            var n = 0
            for x in stride(from: 0, to: w, by: step) where abs(Int(gray[row + x]) - bg) > 48 { n += 1 }
            count[y] = n
        }
        let inked = count.map { $0 > blank }
        // bands of inked rows
        var bands: [(start: Int, end: Int)] = []
        var start: Int?
        for y in 0...h {
            let ink = y < h && inked[y]
            if ink, start == nil { start = y }
            if !ink, let s = start { bands.append((s, y)); start = nil }
        }
        let inner = bands.filter { $0.start > 0 && $0.end < h }.map { $0.end - $0.start }.sorted()
        guard bands.count >= 2, !inner.isEmpty else { return img }
        let line = Double(inner[inner.count / 2])
        /// low, and its edge row holds at least half the ink of its densest row
        func cut(_ b: (start: Int, end: Int), edge: Int) -> Bool {
            guard Double(b.end - b.start) < 0.75 * line else { return false }
            let densest = count[b.start..<b.end].max() ?? 0
            return densest > 0 && Double(count[edge]) >= 0.5 * Double(densest)
        }
        var top = 0, bottom = h
        if let first = bands.first, first.start == 0, cut(first, edge: 0) { top = first.end }
        if let last = bands.last, last.end == h, last.start > top, cut(last, edge: h - 1) { bottom = last.start }
        guard top > 0 || bottom < h, bottom - top >= 16,
              let cut = img.cropping(to: CGRect(x: 0, y: top, width: w, height: bottom - top)) else { return img }
        return cut
    }

    // MARK: recognition

    /// text: plain, tables as Markdown (what chat apps like Claude understand); html: with a real
    /// table (Notizen, Mail, Numbers, Excel, Word); tsv: the tables tab-separated, for spreadsheets
    struct Result { var text: String; var html: String?; var tables: Int; var tsv: String? = nil; var words = 0 }

    /// a table as Vision reports it: every cell at its first row and column, the positions a
    /// merged cell spans over marked `covered`
    struct Cell { var text: String; var rowSpan = 1; var colSpan = 1; var covered = false }
    typealias Grid = [[Cell]]
    struct Item { var marker: String; var text: String }
    enum Kind { case text(String), list([Item], ordered: Bool), table(Grid) }
    /// one block of the page; rect normalised, origin bottom left (Vision's)
    struct Block { var rect: CGRect; var kind: Kind; var multiLine: Bool }
    struct Page { var blocks: [Block]; var lineHeight: CGFloat }

    /// a tiny image WITH text (a blank one lets the recognition stop early and load nothing),
    /// and the spell checker and language model the umlaut repair uses
    static func warm() {
        let size = NSSize(width: 360, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("Prüfung Tabelle 2026" as NSString).draw(at: NSPoint(x: 10, y: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // one pass of the classic recogniser first: afterwards the document request takes ~200
        // instead of ~340 ms (measured 04.10., stable; it seems to load the model a faster way)
        let classic = VNRecognizeTextRequest()
        classic.recognitionLevel = .accurate
        classic.recognitionLanguages = ["de-DE", "en-US"]
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([classic])
        if #available(macOS 26.0, *) { Task.detached(priority: .userInitiated) { _ = await structured(cg) } }
        _ = render(Page(blocks: [Block(rect: .zero, kind: .text("Die Prufung ist fur alle offen"), multiLine: false)],
                        lineHeight: 0.1))
    }

    /// waits for an async Vision call from this plain (non-async) loop
    static func blocking<T>(_ work: @escaping () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        var value: T?
        // the user is waiting: Vision's GPU/ANE work runs at this priority (default: ~2x slower)
        Task.detached(priority: .userInitiated) { value = await work(); sem.signal() }
        sem.wait()
        return value!
    }

    /// on the main thread: Vision runs in a task, the text repair (NSSpellChecker) here
    static var lastSplit = (vision: 0, repair: 0)

    static func recognise(_ img: CGImage, retry: Bool = true, keepLines: Bool = false) -> Result {
        let t0 = Date()
        var page: Page
        if keepLines {
            // Terminal and code editors: no paragraphs (Apple's would join lines of code and
            // output, 04.10., Nils), every line as on screen
            page = monoPage(IconFilter.cleanLines(classicLines(img), img))
        } else if #available(macOS 26.0, *) {
            // the document request (paragraphs, lists, tables, reading order) starts at once; the
            // classic recogniser (TextShot's engine, faster) runs alongside and answers a single
            // line on its own, at TextShot's speed
            let sem = DispatchSemaphore(value: 0)
            var doc: Page?
            Task.detached(priority: .userInitiated) { doc = await structured(img); sem.signal() }
            // a big region is never a single line: no second recogniser alongside (5K screen:
            // 740 MB peak with both)
            let big = img.width * img.height > 3_000_000
            let lines = big ? [] : IconFilter.cleanLines(classicLines(img), img)
            // (no line at all: the document request may still read it, Chinese or Japanese)
            if !big && lines.count == 1 {
                page = linePage(lines)
            } else {
                sem.wait()
                page = (doc?.blocks.isEmpty == false ? doc : nil) ?? linePage(big ? classicLines(img) : lines)
            }
        } else {
            page = linePage(classicLines(img))
        }
        let t1 = Date()
        let r = render(page)
        lastSplit = (Int(t1.timeIntervalSince(t0) * 1000), Int(Date().timeIntervalSince(t1) * 1000))
        // small text at 1x is below what Vision reads; twice the size reads it (04.10.: an 11 pt
        // block of 460 x 64 px gave nothing in either engine, everything when doubled)
        if r.text.isEmpty, retry, img.width * img.height <= 1_500_000, let big = upscaled(img) {
            return recognise(big, retry: false, keepLines: keepLines)
        }
        return r
    }

    static func upscaled(_ img: CGImage) -> CGImage? {
        let w = img.width * 2, h = img.height * 2
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// macOS 26: Apple's document layout. Its paragraphs are right where TextShot's lines are not
    /// (wrapped lines joined, hyphenation undone, addresses and logs kept line by line; 04.10.)
    @available(macOS 26.0, *)
    static func structured(_ img: CGImage) async -> Page? {
        var req = RecognizeDocumentsRequest()
        req.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "de-DE"), Locale.Language(identifier: "en-US")]
        req.textRecognitionOptions.useLanguageCorrection = true
        guard let doc = (try? await req.perform(on: img, orientation: .up))?.first?.document else { return nil }
        let icons = IconFilter(img, doc: doc)
        var blocks: [Block] = []
        var taken: [CGRect] = []
        func inside(_ r: CGRect, _ area: CGRect) -> Bool {
            area.insetBy(dx: -0.01, dy: -0.01).contains(CGPoint(x: r.midX, y: r.midY))
        }
        for t in doc.tables {
            let r = t.boundingRegion.boundingBox.cgRect
            taken.append(r)
            var g = grid(t, icons)
            trimEmpty(&g)
            if isTable(g) {
                blocks.append(Block(rect: r, kind: .table(g), multiLine: true))
            } else {
                // text columns (or a list) Vision took for a table: each column top to bottom
                blocks += columnBlocks(t, icons)
            }
        }
        for l in doc.lists {
            let r = l.boundingRegion.boundingBox.cgRect
            taken.append(r)
            let ordered: Set<DocumentObservation.Container.List.Marker> =
                [.decimal, .decorativeDecimal, .compositeDecimal, .lowercaseLatin, .uppercaseLatin]
            let isOrdered = l.items.contains { $0.markerType.map(ordered.contains) ?? false }
            let items = l.items.enumerated().map { i, item -> Item in
                let text = breaks(item.itemString)          // a line under the item ("Hinweis: …") stays its own line
                let marker = item.markerString.trimmingCharacters(in: .whitespaces)
                return Item(marker: isOrdered ? (marker.isEmpty ? "\(i + 1)." : marker) : "-", text: text)
            }.filter { !$0.text.isEmpty }
            if !items.isEmpty { blocks.append(Block(rect: r, kind: .list(items, ordered: isOrdered), multiLine: true)) }
        }
        var heights: [CGFloat] = []
        for p in doc.paragraphs {
            heights += p.lines.map { CGFloat($0.boundingBox.height) }
            let r = p.boundingRegion.boundingBox.cgRect
            if taken.contains(where: { inside(r, $0) }) { continue }
            // Apple's transcript: wrapped lines already joined, real breaks (code) kept
            let text = breaks(icons.clean(p))
            // flowing text (wrapped lines joined) stands apart; lines Apple kept as lines (code) do not
            if !text.isEmpty { blocks.append(Block(rect: r, kind: .text(text), multiLine: p.lines.count > 1 && !text.contains("\n"))) }
        }
        return Page(blocks: blocks, lineHeight: median(heights) ?? 0.05)
    }

    @available(macOS 26.0, *)
    static func grid(_ t: DocumentObservation.Container.Table, _ icons: IconFilter? = nil) -> Grid {
        let cells = t.rows.flatMap { $0 }
        let rows = (cells.map(\.rowRange.upperBound).max() ?? -1) + 1
        let cols = (cells.map(\.columnRange.upperBound).max() ?? -1) + 1
        var g = Array(repeating: Array(repeating: Cell(text: ""), count: cols), count: rows)
        var seen = Set<[Int]>()
        for c in cells {
            let r0 = c.rowRange.lowerBound, c0 = c.columnRange.lowerBound
            guard seen.insert([r0, c0]).inserted else { continue }
            g[r0][c0] = Cell(text: cellText(icons?.clean(c.content.text) ?? c.content.text.transcript), rowSpan: c.rowRange.count, colSpan: c.columnRange.count)
            for r in c.rowRange { for k in c.columnRange where r != r0 || k != c0 { g[r][k].covered = true } }
        }
        return g
    }

    static func cellText(_ s: String) -> String {
        breaks(s).replacingOccurrences(of: "\\s*\\n\\s*", with: " ", options: .regularExpression)
    }

    /// Vision marks a real line break inside a paragraph or list item with U+2028 (LINE
    /// SEPARATOR), which most apps paste as nothing: a plain line break instead
    static func breaks(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// drops rows and columns with nothing in them (Vision adds them around labels and logs);
    /// only plain ones, a merged cell keeps its row and column
    static func trimEmpty(_ g: inout Grid) {
        func plainEmpty(_ c: Cell) -> Bool { !c.covered && c.text.isEmpty && c.rowSpan == 1 && c.colSpan == 1 }
        g.removeAll { $0.allSatisfy(plainEmpty) }
        guard let cols = g.first?.count else { return }
        for k in (0..<cols).reversed() where g.allSatisfy({ plainEmpty($0[k]) }) {
            for r in g.indices { g[r].remove(at: k) }
        }
    }

    /// a real table, not text columns Vision read as one (04.10.: a two-column article and a log came
    /// out as tables). Text columns run on in at least two columns: a cell stops mid-sentence (lower
    /// case below, or it ends on an article, a conjunction or a comma); one description column alone
    /// (Option | Beschreibung) is still a table. Long prose in most cells and hardly a figure means
    /// columns of text, unless a short header row (Risiko | Maßnahme) says table.
    static let dangling: Set<String> = ["der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
                                        "und", "oder", "aber", "sowie", "dass", "the", "a", "and", "or", "of", "to"]
    static func isTable(_ g: Grid) -> Bool {
        let rows = g.count, cols = g.first?.count ?? 0
        guard rows >= 2, cols >= 2 else { return false }
        let texts = g.flatMap { $0 }.filter { !$0.covered && !$0.text.isEmpty }.map(\.text)
        guard texts.count >= 3 else { return false }
        var flowingColumns = 0
        for k in 0..<cols {
            var flows = 0
            for r in 0..<(rows - 1) {
                let a = g[r][k], b = g[r + 1][k]
                guard !a.covered, !b.covered, !a.text.isEmpty, !b.text.isEmpty else { continue }
                let words = a.text.split(separator: " ")
                guard words.count >= 3, let end = a.text.last, !".:!?;".contains(end) else { continue }
                let last = words.last!.lowercased()
                if (b.text.first?.isLowercase ?? false) || end == "," || dangling.contains(last) { flows += 1 }
            }
            if flows >= 1 { flowingColumns += 1 }
        }
        if flowingColumns >= 2 { return false }
        let head = g[0].filter { !$0.covered && !$0.text.isEmpty }
        let header = head.count >= 2 && head.allSatisfy { $0.text.split(separator: " ").count <= 2 && !".,;!?".contains($0.text.last!) }
        if !header {
            let long = texts.filter { $0.split(separator: " ").count >= 5 }.count
            let figures = texts.filter { $0.contains(where: \.isNumber) }.count
            if Double(long) >= 0.6 * Double(texts.count) && Double(figures) < 0.2 * Double(texts.count) { return false }
        }
        return true
    }

    @available(macOS 26.0, *)
    static func columnBlocks(_ t: DocumentObservation.Container.Table, _ icons: IconFilter? = nil) -> [Block] {
        var columns: [Int: [(row: Int, text: String, rect: CGRect)]] = [:]
        for c in t.rows.flatMap({ $0 }) {
            let text = cellText(icons?.clean(c.content.text) ?? c.content.text.transcript)
            if text.isEmpty { continue }
            columns[c.columnRange.lowerBound, default: []].append((c.rowRange.lowerBound, text, c.content.boundingRegion.boundingBox.cgRect))
        }
        return columns.keys.sorted().compactMap { k in
            guard let cells = columns[k]?.sorted(by: { $0.row < $1.row }), let first = cells.first else { return nil }
            let rect = cells.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            return Block(rect: rect, kind: .text(cells.map(\.text).joined(separator: "\n")), multiLine: cells.count > 1)
        }
    }

    typealias Line = (text: String, box: CGRect)

    /// TextShot's engine: accurate, language correction; lines top to bottom
    static func classicLines(_ img: CGImage) -> [Line] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["de-DE", "en-US"]
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results ?? []).compactMap { o in o.topCandidates(1).first.map { ($0.string, o.boundingBox) } }
            .sorted { $0.box.maxY > $1.box.maxY }
    }

    /// the classic lines as TextShot gives them, but one visual row per line: cells side by side
    /// (macOS 15 has no document layout) come out in their order, tab-separated
    static func linePage(_ lines: [Line]) -> Page {
        guard !lines.isEmpty else { return Page(blocks: [], lineHeight: 0.05) }
        var rows: [[Line]] = []
        for l in lines {
            if let last = rows.last, let ref = last.first,
               min(ref.box.maxY, l.box.maxY) - max(ref.box.minY, l.box.minY) > 0.5 * min(ref.box.height, l.box.height) {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        let text = rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "\t") }
            .joined(separator: "\n")
        let rect = lines.dropFirst().reduce(lines[0].box) { $0.union($1.box) }
        return Page(blocks: [Block(rect: rect, kind: .text(text), multiLine: rows.count > 1)],
                    lineHeight: median(lines.map(\.box.height)) ?? 0.05)
    }

    /// monospaced text as it stands: indentation and the gaps between columns (ls -l, ps) as
    /// spaces, one character being as wide as any other; an empty line where the screen has one
    /// between blocks of code
    static func monoPage(_ lines: [Line]) -> Page {
        guard !lines.isEmpty else { return Page(blocks: [], lineHeight: 0.05) }
        let samples = lines.filter { $0.text.count >= 4 }.map { $0.box.width / CGFloat($0.text.count) }
        guard let charW = median(samples), charW > 0 else { return linePage(lines) }
        var rows: [[Line]] = []
        for l in lines {
            if let last = rows.last, let ref = last.first,
               min(ref.box.maxY, l.box.maxY) - max(ref.box.minY, l.box.minY) > 0.5 * min(ref.box.height, l.box.height) {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        let left = lines.map(\.box.minX).min() ?? 0
        let tops = rows.map { $0.map(\.box.midY).max() ?? 0 }
        let pitch = median(zip(tops, tops.dropFirst()).map { $0 - $1 }.filter { $0 > 0 }) ?? 0
        var out: [String] = []
        for (i, row) in rows.enumerated() {
            if i > 0, pitch > 0 {
                let blank = Int(((tops[i - 1] - tops[i]) / pitch).rounded()) - 1
                if blank > 0 { out += Array(repeating: "", count: min(blank, 2)) }
            }
            var s = ""
            for l in row.sorted(by: { $0.box.minX < $1.box.minX }) {
                let col = Int(((l.box.minX - left) / charW).rounded())
                if s.count < col { s += String(repeating: " ", count: col - s.count) } else if !s.isEmpty { s += " " }
                s += l.text
            }
            out.append(s)
        }
        let rect = lines.dropFirst().reduce(lines[0].box) { $0.union($1.box) }
        return Page(blocks: [Block(rect: rect, kind: .text(out.joined(separator: "\n")), multiLine: false)],
                    lineHeight: median(lines.map(\.box.height)) ?? 0.05)
    }

    static func median(_ v: [CGFloat]) -> CGFloat? {
        v.isEmpty ? nil : v.sorted()[v.count / 2]
    }

    // MARK: reading order

    /// Breuel's rules: a block comes before another below it in the same column, and before one
    /// entirely to its right unless something spanning both lies between them (a heading over
    /// two columns). Then the topmost ready block first. Columns are read one after the other.
    static func readingOrder(_ r: [CGRect], tall: [Bool] = []) -> [Int] {
        let n = r.count
        guard n > 1 else { return Array(0..<n) }
        let eps: CGFloat = 0.004
        func xOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat { min(a.maxX, b.maxX) - max(a.minX, b.minX) }
        var succ = Array(repeating: [Int](), count: n)
        var indegree = Array(repeating: 0, count: n)
        for a in 0..<n {
            for b in 0..<n where a != b {
                let A = r[a], B = r[b]
                var before = false
                if xOverlap(A, B) > eps {
                    before = A.midY > B.midY
                } else if A.maxX <= B.minX + eps {
                    let lo = min(A.midY, B.midY), hi = max(A.midY, B.midY)
                    before = !(0..<n).contains { c in
                        c != a && c != b && r[c].midY > lo && r[c].midY < hi && xOverlap(r[c], A) > eps && xOverlap(r[c], B) > eps
                    }
                    if before && !tall.isEmpty { before = sideBySide(a, b, r, tall) }
                }
                if before { succ[a].append(b); indegree[b] += 1 }
            }
        }
        func higher(_ i: Int, _ j: Int) -> Bool { r[i].maxY != r[j].maxY ? r[i].maxY > r[j].maxY : r[i].minX < r[j].minX }
        var order: [Int] = [], done = Set<Int>()
        var ready = (0..<n).filter { indegree[$0] == 0 }
        while order.count < n {
            if ready.isEmpty, let top = (0..<n).filter({ !done.contains($0) }).min(by: higher) {
                ready = [top]                                          // a cycle (overlapping blocks): break it at the top
            }
            ready.sort(by: higher)
            let next = ready.removeFirst()
            if !done.insert(next).inserted { continue }
            order.append(next)
            for s in succ[next] {
                indegree[s] -= 1
                if indegree[s] == 0 && !done.contains(s) { ready.append(s) }
            }
        }
        return order
    }

    /// "Left column first" only where the two sides really run side by side: the two blocks share a
    /// row, or somewhere a block of A's column and one of B's share a row and one of them is a
    /// paragraph of several lines. Chat bubbles alternate and never do (04.10.: a chat came out as all
    /// left bubbles, then all right ones). A single line below all paragraphs of B's column with a
    /// partner on B's side is a footer row, not the end of the left column.
    static func sideBySide(_ a: Int, _ b: Int, _ r: [CGRect], _ tall: [Bool]) -> Bool {
        let eps: CGFloat = 0.004
        func xo(_ p: CGRect, _ q: CGRect) -> Bool { min(p.maxX, q.maxX) - max(p.minX, q.minX) > eps }
        func row(_ p: CGRect, _ q: CGRect) -> Bool { min(p.maxY, q.maxY) - max(p.minY, q.minY) > 0.3 * min(p.height, q.height) }
        let A = r[a], B = r[b]
        if row(A, B) { return true }
        let colA = r.indices.filter { xo(r[$0], A) }, colB = r.indices.filter { xo(r[$0], B) }
        let evidence = colA.contains { c in colB.contains { d in
            c != d && r[c].maxX <= r[d].minX + eps && row(r[c], r[d]) && (tall[c] || tall[d]) } }
        guard evidence else { return false }
        if !tall[a] {
            let tallB = colB.filter { tall[$0] }
            if !tallB.isEmpty, tallB.allSatisfy({ A.maxY < r[$0].minY }),
               colB.contains(where: { $0 != a && !tall[$0] && row(r[$0], A) }) { return false }
        }
        return true
    }

    // MARK: output

    static func render(_ page: Page) -> Result {
        let raw = page.blocks.flatMap { b -> [String] in
            switch b.kind {
            case .text(let t): return [t]
            case .list(let items, _): return items.map(\.text)
            case .table(let g): return g.flatMap { $0 }.map(\.text)
            }
        }
        let repair = Repair(raw)
        let h = page.lineHeight
        var plain = "", html: [String] = [], tsv: [String] = []
        var tables = 0
        var prev: Block?
        var rowStart: Block?
        for i in readingOrder(page.blocks.map(\.rect), tall: page.blocks.map { $0.rect.height >= 1.8 * page.lineHeight }) {
            let b = page.blocks[i]
            var piece = ""
            switch b.kind {
            case .text(let t):
                let fixed = repair.fix(t)
                piece = fixed
                html.append("<p>" + escape(fixed).replacingOccurrences(of: "\n", with: "<br>") + "</p>")
            case .list(let items, let ordered):
                let fixed = items.map { Item(marker: $0.marker, text: repair.fix($0.text)) }
                piece = fixed.map { item in
                    let indent = String(repeating: " ", count: item.marker.count + 1)
                    return item.marker + " " + item.text.replacingOccurrences(of: "\n", with: "\n" + indent)
                }.joined(separator: "\n")
                let tag = ordered ? "ol" : "ul"
                var attrs = ""
                // Notizen, Mail and Word number an <ol> themselves: keep "a)" lists and a list from "3."
                if ordered, let m = fixed.first?.marker.trimmingCharacters(in: CharacterSet(charactersIn: ".)( ")) {
                    if let n = Int(m) { if n != 1 { attrs = " start=\"\(n)\"" } }
                    else if m.count == 1, let ch = m.unicodeScalars.first, CharacterSet.letters.contains(ch) {
                        let lower = m.lowercased()
                        attrs = " type=\"\(m == lower ? "a" : "A")\"" + (lower == "a" ? "" : " start=\"\(Int(lower.unicodeScalars.first!.value) - 96)\"")
                    }
                }
                html.append("<\(tag)\(attrs)>" + fixed.map { "<li>" + escape($0.text).replacingOccurrences(of: "\n", with: "<br>") + "</li>" }.joined() + "</\(tag)>")
            case .table(let g):
                tables += 1
                let cells = g.map { $0.map { $0.covered ? "" : repair.fix($0.text) } }
                piece = markdown(cells)
                tsv.append(cells.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
                html.append(tableHTML(g, cells))
            }
            if let p = prev {
                var sep = separator(p, b, lineHeight: h)
                // after a row of cells joined by tabs, the next row starts below the row's first cell
                if sep == "\n\n", let rs = rowStart, rs.rect != p.rect, separator(rs, b, lineHeight: h) == "\n" { sep = "\n" }
                if sep != "\t" && sep != " " { rowStart = b }
                plain += sep
            } else { rowStart = b }
            plain += piece
            prev = b
        }
        let words = plain.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
        // HTML only when there is a table: Notizen, Mail and Word then paste a real table
        let htmlDoc = tables > 0 ? "<meta charset=\"utf-8\">" + html.joined(separator: "\n") : nil
        return Result(text: plain, html: htmlDoc, tables: tables, tsv: tsv.isEmpty ? nil : tsv.joined(separator: "\n\n"),
                      words: words)
    }

    /// a line break between single lines that follow each other in one column (address lines,
    /// a menu, a log), an empty line around paragraphs, lists and tables and where a column ends
    /// (Markdown would glue a line straight after a list to its last item)
    /// in line heights: an icon dropped from a sentence leaves at most ~0.45, columns of a form,
    /// an order or a table header start at ~0.6 (04.10., 14 pictures)
    static let smallGap: CGFloat = 0.5
    static func separator(_ a: Block, _ b: Block, lineHeight h: CGFloat) -> String {
        guard case .text = a.kind, case .text = b.kind, !a.multiLine, !b.multiLine else { return "\n\n" }
        // the next cell of the same visual row (a form, a price after its item): a tab; a short gap
        // (where an icon stood in a sentence) is just a space
        if b.rect.minX >= a.rect.maxX - 0.004,
           min(a.rect.maxY, b.rect.maxY) - max(a.rect.minY, b.rect.minY) > 0.5 * min(a.rect.height, b.rect.height) {
            return b.rect.minX - a.rect.maxX < smallGap * h ? " " : "\t"
        }
        let below = b.rect.maxY <= a.rect.minY + 0.5 * h
        let sameColumn = min(a.rect.maxX, b.rect.maxX) - max(a.rect.minX, b.rect.minX) > 0
        return below && sameColumn ? "\n" : "\n\n"
    }

    static func tableHTML(_ g: Grid, _ cells: [[String]]) -> String {
        var rows: [String] = []
        for (r, row) in g.enumerated() {
            var tds = ""
            for (k, c) in row.enumerated() where !c.covered {
                let spans = (c.colSpan > 1 ? " colspan=\"\(c.colSpan)\"" : "") + (c.rowSpan > 1 ? " rowspan=\"\(c.rowSpan)\"" : "")
                tds += "<td\(spans)>\(escape(cells[r][k]))</td>"
            }
            rows.append("<tr>" + tds + "</tr>")
        }
        return "<table border=\"1\" cellpadding=\"4\" style=\"border-collapse:collapse\">" + rows.joined() + "</table>"
    }

    /// a Markdown table: header row, separator, rows; pipes inside cells escaped
    static func markdown(_ rows: [[String]]) -> String {
        guard let width = rows.map(\.count).max(), width > 0 else { return "" }
        let cells = rows.map { row in (row + Array(repeating: "", count: width - row.count)).map {
            $0.replacingOccurrences(of: "|", with: "\\|") } }
        let line = { (r: [String]) in "| " + r.joined(separator: " | ") + " |" }
        return ([line(cells[0]), line(Array(repeating: "---", count: width))] + cells.dropFirst().map(line))
            .joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: text repair

    /// Apple's engines read small umlauts as plain vowels ("Prufung"). Repaired only in German
    /// text (an English line keeps "fur" and "Uber"), never inside a link, an address, a path or
    /// an identifier ("…/fur-sale", "uber.support@…", "spat-fix"), and at most two umlauts a word
    /// ("Prufungsgebuhr").
    struct Repair {
        let german: Bool

        init(_ texts: [String]) {
            german = Self.language(texts.joined(separator: " ")) == .german
        }

        static func language(_ s: String) -> NLLanguage? {
            let r = NLLanguageRecognizer()
            r.processString(s)
            return r.dominantLanguage
        }

        /// a segment long enough to tell its own language decides for itself; a short one (a
        /// table cell, a label) goes with the whole capture
        func fix(_ s: String) -> String {
            let words = s.split(whereSeparator: \.isWhitespace).count
            var isGerman = words >= 5 ? Self.language(s) == .german : german
            if isGerman, words >= 2, words < 5 {
                // a short segment that is clearly English ("fur coat", "That was rude") keeps its words
                let r = NLLanguageRecognizer()
                r.languageConstraints = [.german, .english]
                r.processString(s)
                if (r.languageHypotheses(withMaximum: 2)[.english] ?? 0) >= 0.9 { isGerman = false }
            }
            return isGerman ? OCRHelper.fixUmlauts(s) : s
        }
    }

    static let tokenPattern = try! NSRegularExpression(pattern: "\\S+")
    static let wordPattern = try! NSRegularExpression(pattern: "\\p{L}+")

    static func fixUmlauts(_ s: String) -> String {
        let ns = s as NSString
        var edits: [(NSRange, String)] = []
        for token in tokenPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if technical(ns.substring(with: token.range)) { continue }
            for word in wordPattern.matches(in: s, range: token.range) {
                if let fixed = umlautVariant(ns.substring(with: word.range)) { edits.append((word.range, fixed)) }
            }
        }
        let out = NSMutableString(string: s)
        for (range, text) in edits.reversed() { out.replaceCharacters(in: range, with: text) }
        return out as String
    }

    /// a link, a mail address, a path, a file name, an identifier: written as it is, no repair
    static func technical(_ token: String) -> Bool {
        if token.contains(where: { "/@\\_=#{}<>|".contains($0) }) { return true }
        if token.range(of: "\\p{L}\\.\\p{L}", options: .regularExpression) != nil { return true }   // example.com, notes.txt
        let core = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}.,;:!?\"'„“”‚‘’»«"))
        if core.contains(where: \.isNumber) && core.contains(where: \.isLetter) { return true }      // 25G72, v2
        if core.range(of: "^[a-z]+(-[a-z0-9]+)+$", options: .regularExpression) != nil { return true }  // kebab-case
        return false
    }

    static var spellCache: [String: Bool] = [:]

    /// "Prufung" -> "Prüfung": a word German does not know whose umlaut variant it does
    static func umlautVariant(_ w: String) -> String? {
        guard w.count > 2, !germanWord(w) else { return nil }
        let pairs: [Character: Character] = ["a": "ä", "o": "ö", "u": "ü", "A": "Ä", "O": "Ö", "U": "Ü"]
        let chars = Array(w)
        let spots = chars.indices.filter { pairs[chars[$0]] != nil }.prefix(8)
        for i in spots {
            var v = chars
            v[i] = pairs[chars[i]]!
            if germanWord(String(v)) { return String(v) }
        }
        for (n, i) in spots.enumerated() {
            for j in spots.dropFirst(n + 1) {
                var v = chars
                v[i] = pairs[chars[i]]!
                v[j] = pairs[chars[j]]!
                if germanWord(String(v)) { return String(v) }
            }
        }
        return nil
    }

    static func germanWord(_ w: String) -> Bool {
        if let known = spellCache[w] { return known }
        let ok = NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "de", wrap: false,
                                                     inSpellDocumentWithTag: 0, wordCount: nil).length == 0
        spellCache[w] = ok
        return ok
    }
}
