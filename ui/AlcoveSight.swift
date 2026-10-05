// Alcove "Automatisch" (05.10., Nils): does Alcove show something in the notch right now? The
// guess from "is sound playing" was wrong twice: for ~5 s after a pause (macOS keeps the flag up)
// and with YouTube playing while Alcove shows a paused song (Alcove shows nothing). So VoiceBud
// looks: while the dictation keys are down (the take starts on their release, 100-300 ms later),
// Apple's screencapture takes Alcove's own notch window (70-80 ms, the same tool and permission as
// the Texterkennung), and drawn pixels beside the hardware notch mean Alcove shows something
// (measured 05.10.: 1.7 % with a song showing, 0 % idle, track changes dip briefly).
// Never on the island's way: the island reads the answer if one is there, else it guesses as
// before. Only with Alcove running, "Automatisch" and the Screen Recording permission.
import AppKit

@MainActor
final class AlcoveSight {
    static let shared = AlcoveSight()

    private var answer: (shows: Bool, at: Date)?
    private var looking = false
    private var waiters: [() -> Void] = []
    private var started = Date.distantPast

    /// a look is under way: the island may wait for it, but only until `started + seconds`
    func waitForLook(atMost seconds: TimeInterval, _ then: @escaping () -> Void) -> Bool {
        let left = started.addingTimeInterval(seconds).timeIntervalSinceNow
        guard looking, left > 0 else { return false }
        var called = false
        let once = { if !called { called = true; then() } }
        waiters.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + left) { once() }
        return true
    }

    /// the answer of a look from the last few seconds (the keys went down just before)
    func recent(within seconds: TimeInterval = 3) -> Bool? {
        guard let a = answer, Date().timeIntervalSince(a.at) < seconds else { return nil }
        return a.shows
    }

    /// `done`: on the main thread once this look (or the one already running) has an answer or none
    func look(notchWidth: CGFloat, scale: CGFloat, top: CGFloat = 0, done: (() -> Void)? = nil) {
        if let done { waiters.append(done) }
        guard !looking else { return }
        looking = true
        let t0 = Date()
        started = t0
        DispatchQueue.global(qos: .userInitiated).async {
            let shows = Self.capture(notchWidth: notchWidth, scale: scale, top: top)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.looking = false
                    if let shows {
                        self.answer = (shows, Date())
                        IPC.log("alcove: \(shows ? "shows something" : "shows nothing") (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
                    }
                    let waiting = self.waiters
                    self.waiters = []
                    waiting.forEach { $0() }
                }
            }
        }
    }

    /// Alcove's topmost window at the top of the screen, taken by screencapture; nil when there is
    /// none or the picture fails (the island then guesses as before)
    nonisolated static func capture(notchWidth: CGFloat, scale: CGFloat, top: CGFloat = 0) -> Bool? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.filter {
            ($0[kCGWindowOwnerName as String] as? String) == "Alcove"
                && abs((($0[kCGWindowBounds as String] as? [String: Any])?["Y"] as? CGFloat ?? -999) - top) <= 0.5
        }
        guard let top = windows.max(by: { ($0[kCGWindowLayer as String] as? Int ?? 0) < ($1[kCGWindowLayer as String] as? Int ?? 0) }),
              let id = top[kCGWindowNumber as String] as? Int else { return nil }
        // the Texterkennung's prefix: a leftover from a crash is cleared at the next start
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voicebud-ocr-alcove-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(id), "-t", "png", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // (waitUntilExit polls and cost ~60 ms of the ~75; capped at 1 s, it must never hang)
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        guard (try? p.run()) != nil else { return nil }
        if done.wait(timeout: .now() + 1) == .timedOut {
            p.terminate()
            return nil
        }
        guard p.terminationStatus == 0,
              let image = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return besideNotch(image, notchWidth: notchWidth, scale: scale) >= 0.01
    }

    /// share of drawn pixels left and right of the hardware notch (Alcove's idle window draws
    /// only into the notch itself)
    nonisolated static func besideNotch(_ image: CGImage, notchWidth: CGFloat, scale: CGFloat) -> Double {
        // a quarter of the size is plenty to see whether anything is drawn (and 16x fewer pixels)
        let w = max(1, image.width / 4), h = max(1, image.height / 4)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let fraction = min(1, notchWidth / (CGFloat(image.width) / max(scale, 1)))
        let left = Int(CGFloat(w) * (0.5 - fraction / 2)), right = Int(CGFloat(w) * (0.5 + fraction / 2))
        var drawn = 0, total = 0
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w where x < left || x > right {
                total += 1
                if buf[row + x * 4 + 3] > 40 { drawn += 1 }
            }
        }
        return total > 0 ? Double(drawn) / Double(total) : 0
    }
}
