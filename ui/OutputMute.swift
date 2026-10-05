// Mutes the default output device while VoiceBud records (settings muteWhileRecording) and
// restores it afterwards, unless an exception app (a call in Teams, Zoom, FaceTime) is in front
// or playing sound. A marker file (the device's UID) survives a crash and a device that left
// while muted, so the sound comes back on that device: at the next start or the next take.
import AppKit
import CoreAudio

@MainActor
enum OutputMute {
    private static var muted: (device: AudioObjectID, before: UInt32)?
    private static var pending: DispatchWorkItem?
    private static var marker: URL { Paths.dataDir.appendingPathComponent("muted-by-voicebud") }

    /// recording started: mute after the start sound has played
    static func begin(_ settings: UISettings) {
        restorePending()
        guard settings.muteWhileRecording, muted == nil, !exceptionActive(settings.muteExceptions) else { return }
        let work = DispatchWorkItem { MainActor.assumeIsolated { muteNow() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (settings.sounds ? 0.25 : 0), execute: work)
    }

    /// recording ended (or the app quits): sound back, unless the user changed it meanwhile
    static func end() {
        pending?.cancel()
        pending = nil
        guard let m = muted else { restorePending(); return }
        muted = nil
        guard let state = mute(of: m.device) else { return }   // device gone: its line stays
        if state == 1 { setMute(m.device, m.before) }
        let uid = uid(of: m.device) ?? ""
        writeMarker(pendingLines().filter { !$0.hasPrefix(uid + "\t") })
    }

    /// app start: a crash while muted left the marker behind
    static func recoverAfterCrash() { restorePending() }

    /// Marker lines without a running mute: each device gets its sound back once it is there
    /// again (lines older than a day are dropped: by then the user set the mute themselves). An
    /// empty marker from an older version means the default output.
    static func restorePending() {
        guard muted == nil, let text = try? String(contentsOf: marker, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init)
        if lines.isEmpty {
            if let device = defaultOutput(), mute(of: device) == 1 { setMute(device, 0) }
            try? FileManager.default.removeItem(at: marker)
            return
        }
        var keep: [String] = []
        for line in lines {
            let parts = line.split(separator: "\t").map(String.init)
            guard let uid = parts.first, !uid.isEmpty else { continue }
            let age = Date().timeIntervalSince1970 - (Double(parts.count > 1 ? parts[1] : "") ?? 0)
            if age > 86_400 { continue }
            if let device = device(forUID: uid) {
                if mute(of: device) == 1 { setMute(device, 0) }
            } else {
                keep.append(line)                 // not back yet
            }
        }
        writeMarker(keep)
    }

    private static func pendingLines() -> [String] {
        ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private static func writeMarker(_ lines: [String]) {
        if lines.isEmpty {
            try? FileManager.default.removeItem(at: marker)
        } else {
            try? (lines.joined(separator: "\n") + "\n").write(to: marker, atomically: true, encoding: .utf8)
        }
    }

    private static func muteNow() {
        pending = nil
        guard muted == nil, let device = defaultOutput(), let before = mute(of: device), before == 0 else { return }
        guard setMute(device, 1) else { return }        // a device without mute (some HDMI) stays as it is
        muted = (device, before)
        // one line per muted device, added to devices still waiting for their sound
        let uid = uid(of: device) ?? ""
        let others = pendingLines().filter { !$0.hasPrefix(uid + "\t") }
        writeMarker(others + ["\(uid)\t\(Int(Date().timeIntervalSince1970))"])
    }

    // -- exceptions --------------------------------------------------------------------------
    private static func exceptionActive(_ bundles: [String]) -> Bool {
        let wanted = Set(bundles.map { $0.lowercased() })
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased(), wanted.contains(front) {
            return true
        }
        return playingBundles().contains { wanted.contains($0.lowercased()) }
    }

    /// bundle ids of processes whose output runs right now (macOS 14.4+ process objects)
    private static func playingBundles() -> [String] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }
        var out: [String] = []
        for object in objects {
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            var a = address(kAudioProcessPropertyIsRunningOutput)
            guard AudioObjectGetPropertyData(object, &a, 0, nil, &s, &running) == noErr, running != 0 else { continue }
            var bundle: Unmanaged<CFString>?
            s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            a = address(kAudioProcessPropertyBundleID)
            if AudioObjectGetPropertyData(object, &a, 0, nil, &s, &bundle) == noErr, let b = bundle?.takeRetainedValue() {
                out.append(b as String)
            }
        }
        return out
    }

    // -- CoreAudio ---------------------------------------------------------------------------
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioObjectID? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let ok = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
        return ok && device != 0 ? device : nil
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr,
              let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }

    private static func device(forUID uid: String) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let ok = withUnsafePointer(to: &cf) { q in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), q, &size, &device) == noErr
        }
        return ok && device != kAudioObjectUnknown ? device : nil
    }

    private static func mute(of device: AudioObjectID) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    private static func setMute(_ device: AudioObjectID, _ value: UInt32) -> Bool {
        var v = value
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return false }
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }
}
