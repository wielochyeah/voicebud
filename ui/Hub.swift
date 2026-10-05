// Hub window (SPEC §5): Verlauf, Wörterbuch and the settings panes in one NSWindow hosting a
// SwiftUI NavigationSplitView. Every visual is plain SwiftUI (no AppKit-backed control in the
// look itself), so HubRender.swift can draw the same views headless with ImageRenderer.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Controller

@MainActor
final class HubController: NSObject, NSWindowDelegate {
    private static let autosaveName = "VoiceBudHub"
    nonisolated(unsafe) private let state: AppState
    private var model: HubModel?
    private var window: NSWindow?
    private var keyMonitor: Any?
    /// the app that was frontmost before the hub took focus; it gets focus back on close, so
    /// the next dictation does not land in the (windowless) helper
    private var previousApp: NSRunningApplication?

    nonisolated init(state: AppState) {
        self.state = state
        super.init()
    }

    private var headless: Bool { ProcessInfo.processInfo.environment["VOICEBUD_UI_HEADLESS"] == "1" }

    func show() {
        let model = self.model ?? HubModel(state: state)
        self.model = model
        model.reloadAll()
        if headless { return }
        let window = self.window ?? makeWindow(model: model)
        self.window = window
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.orderFrontRegardless()
        installKeyMonitor()
    }

    /// a word was learned while the hub is open: show it in the dictionary right away
    func dictionaryDidChange() {
        // also while minimised or hidden: an edit made later would otherwise write back the old
        // list and drop the word the core just learned
        model?.reloadAll()
    }

    func historyDidChange() {
        guard let model else { return }
        if headless || window?.isVisible == true { model.reloadHistory(keepCount: true) }
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let closing = window
        window = nil
        // Drop the SwiftUI tree while closed: no animations, no memory held for a hidden window.
        // The autosave name must be unique among live windows, so the closing one gives it up
        // (its last frame is already stored) before the next show() builds a fresh window.
        DispatchQueue.main.async {
            closing?.setFrameAutosaveName("")
            closing?.contentViewController = nil
            closing?.delegate = nil
        }
        NSApp.setActivationPolicy(.accessory)
        handBackActivation()
    }

    /// Without a window the helper must not stay the active app: the next paste would go
    /// nowhere. Re-activate whoever was frontmost before the hub opened, else just hide
    /// (the island panel has canHide = false, so a running take stays visible).
    private func handBackActivation() {
        let previous = previousApp
        previousApp = nil
        guard NSApp.isActive else { return }
        if let previous, !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            if previous.activate(from: NSRunningApplication.current, options: []) { return }
        }
        NSApp.hide(nil)
    }

    private func makeWindow(model: HubModel) -> NSWindow {
        let host = NSHostingController(rootView: HubRootView(model: model))
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.title = "VoiceBud"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        // An empty unified toolbar gives the 52 pt title band (traffic lights centred in it) that
        // Alcove's settings window has; the pane headers sit inside that band.
        w.toolbar = NSToolbar(identifier: "VoiceBudHub")
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 760, height: 500)
        w.delegate = self
        w.setContentSize(NSSize(width: 900, height: 620))
        if !w.setFrameUsingName(Self.autosaveName) { w.center() }
        w.setFrameAutosaveName(Self.autosaveName)
        return w
    }

    /// The UI helper may run without a main menu, so the editing shortcuts are routed by hand
    /// while the hub is key. ⌘F jumps to the search field, ⌘W closes.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let commandOnly = event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated {
                self?.handleKey(key, commandOnly: commandOnly, windowNumber: windowNumber) ?? false
            }
            return handled ? nil : event
        }
    }

    private func handleKey(_ key: String, commandOnly: Bool, windowNumber: Int) -> Bool {
        guard commandOnly, let w = window, w.windowNumber == windowNumber else { return false }
        switch key {
        case "w":
            w.performClose(nil)
            return true
        case "f":
            model?.focusSearch()
            return true
        default:
            let actions: [String: Selector] = [
                "x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)),
                "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:)),
                "z": Selector(("undo:")),
            ]
            guard let sel = actions[key] else { return false }
            return NSApp.sendAction(sel, to: nil, from: w)
        }
    }
}

// MARK: - Panes and model

struct HubIcon {
    /// nil draws the custom notch glyph
    let symbol: String?
    let top: UInt32
    let bottom: UInt32
}

enum HubPane: String, CaseIterable, Identifiable {
    case verlauf, texterkennung, woerterbuch, kuerzel, insel, welle, alcove, kontext, erkennung, allgemein

    static let top: [HubPane] = [.verlauf, .texterkennung, .woerterbuch, .kuerzel]
    /// the Alcove pane only exists when Alcove is installed
    static var settings: [HubPane] {
        [.insel, .welle, .alcove, .kontext, .erkennung, .allgemein].filter { $0 != .alcove || HubSystem.alcoveInstalled() }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verlauf: return L("Verlauf")
        case .texterkennung: return L("Erkannte Texte")
        case .erkennung: return L("Texterkennung")
        case .woerterbuch: return L("Wörterbuch")
        case .kuerzel: return L("Kürzel")
        case .insel: return L("Insel & Kapsel")
        case .welle: return L("Wellenform")
        case .alcove: return "Alcove"
        case .kontext: return L("Bildschirmkontext")
        case .allgemein: return L("Allgemein")
        }
    }

    var headerTitle: String { self == .alcove ? L("Wenn Alcove läuft") : title }

    var icon: HubIcon {
        switch self {
        case .verlauf: return HubIcon(symbol: "clock.fill", top: 0xC3A8FF, bottom: 0x8F6CF2)
        case .texterkennung: return HubIcon(symbol: "text.viewfinder", top: 0x8CCBFF, bottom: 0x3E92F0)
        case .woerterbuch: return HubIcon(symbol: "book.closed.fill", top: 0xFBBF24, bottom: 0xF59E0B)
        case .kuerzel: return HubIcon(symbol: "text.badge.plus", top: 0x86EFAC, bottom: 0x22C55E)
        case .insel: return HubIcon(symbol: nil, top: 0x3A3A3C, bottom: 0x000000)
        case .welle: return HubIcon(symbol: "waveform", top: 0xFB7185, bottom: 0xF43F5E)
        case .alcove: return HubIcon(symbol: "rectangle.2.swap", top: 0x5EEAD4, bottom: 0x14B8A6)
        case .kontext: return HubIcon(symbol: "text.viewfinder", top: 0x7DB6FF, bottom: 0x3B82F6)
        case .erkennung: return HubIcon(symbol: "doc.text.viewfinder", top: 0xA5B4FC, bottom: 0x6366F1)
        case .allgemein: return HubIcon(symbol: "gearshape.fill", top: 0xA1A1A6, bottom: 0x76767B)
        }
    }
}

struct HubDay: Identifiable {
    let id: Date
    let items: [HistoryEntry]
    /// worked out when drawn, so "Heute" or "Today" follows a language switch
    var label: String { HubFormat.dayLabel(id) }
}

enum HubAddResult: Equatable {
    case added(String), duplicate(String), empty
}

@MainActor
@Observable
final class HubModel {
    let state: AppState
    let isPreview: Bool

    var pane: HubPane = .verlauf {
        didSet {   // Verlauf and Erkannte Texte show the same list view over two histories
            guard pane == .verlauf || pane == .texterkennung, loadedOCR != (pane == .texterkennung) else { return }
            query = ""
            reloadHistory()
        }
    }
    /// which of the two histories the list holds (review 05.10.: Erkannte Texte, a settings pane,
    /// then Verlauf showed the recognized texts under Verlauf)
    private var loadedOCR = false
    var ocrPane: Bool { pane == .texterkennung }
    private(set) var query = ""
    private(set) var entries: [HistoryEntry] = []
    private(set) var days: [HubDay] = []
    private(set) var canLoadMore = false
    private(set) var stats = HistoryStats()
    private(set) var dictationCount = 0
    private(set) var ocrCount = 0
    /// entries in the history the open pane shows
    var totalCount: Int { ocrPane ? ocrCount : dictationCount }
    private(set) var terms: [String] = []
    /// Set by ⌘F; the Verlauf pane consumes it when it appears or is already on screen.
    var searchFocusPending = false

    // Render-only overrides (HubRender.swift): rows drawn hovered/expanded, fixed system facts.
    var previewHover: Int64?
    var previewExpanded: Set<Int64> = []
    var previewHoverTerm: String?
    var previewAlcoveRunning: Bool?
    /// renders only: the snippets list (ImageRenderer never runs onAppear, so the pane would be empty)
    var previewSnippets: [[String: String]] = []

    @ObservationIgnored private let store: HistoryStore?

    init(state: AppState, store: HistoryStore = HistoryStore()) {
        self.state = state
        self.isPreview = false
        self.store = store
    }

    /// In-memory model for renders: never touches the DB, dictionary.json or settings.json.
    init(previewState state: AppState, entries: [HistoryEntry], stats: HistoryStats, total: Int, terms: [String]) {
        self.state = state
        self.isPreview = true
        self.store = nil
        self.entries = entries
        self.stats = stats
        self.dictationCount = total
        self.terms = terms
        regroup()
    }

    func reloadAll() {
        reloadHistory()
        loadTerms()
    }

    // MARK: History

    func setQuery(_ q: String) {
        guard q != query else { return }
        query = q
        reloadHistory()
    }

    func focusSearch() {
        pane = .verlauf
        searchFocusPending = true
    }

    func reloadHistory(keepCount: Bool = false) {
        guard let store else { return }
        loadedOCR = ocrPane
        let limit = keepCount ? max(HistoryStore.pageSize, entries.count) : HistoryStore.pageSize
        let rows = fetch(store, limit: limit, offset: 0)
        entries = rows
        canLoadMore = rows.count == limit
        stats = store.statsToday()
        dictationCount = store.count()
        ocrCount = store.count(ocr: true)
        regroup()
    }

    func loadMore() {
        guard canLoadMore, let store else { return }
        let more = fetch(store, limit: HistoryStore.pageSize, offset: entries.count)
        let known = Set(entries.map(\.id))
        entries += more.filter { !known.contains($0.id) }
        canLoadMore = more.count == HistoryStore.pageSize
        regroup()
    }

    private func fetch(_ store: HistoryStore, limit: Int, offset: Int) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? store.entries(limit: limit, offset: offset, ocr: ocrPane)
                         : store.search(q, limit: limit, offset: offset, ocr: ocrPane)
    }

    private func regroup() {
        let cal = Calendar.current
        var out: [HubDay] = []
        var current: Date?
        var bucket: [HistoryEntry] = []
        for e in entries {
            let day = cal.startOfDay(for: e.date)
            if day != current {
                if let current { out.append(HubDay(id: current, items: bucket)) }
                current = day
                bucket = []
            }
            bucket.append(e)
        }
        if let current { out.append(HubDay(id: current, items: bucket)) }
        days = out
    }

    // MARK: Dictionary

    func loadTerms() {
        guard !isPreview else { return }
        let root = (try? Data(contentsOf: Paths.dictionary))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        terms = (root?["terms"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    func addTerm(_ input: String) -> HubAddResult {
        let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .empty }
        if let existing = terms.first(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            return .duplicate(existing)
        }
        terms.insert(term, at: 0)
        saveTerms()
        return .added(term)
    }

    func removeTerm(_ term: String) {
        terms.removeAll { $0 == term }
        saveTerms()
    }

    private func saveTerms() {
        guard !isPreview else { return }
        state.commitDictionary(terms)
    }

    // MARK: Settings

    func update(_ change: (inout UISettings) -> Void) {
        change(&state.settings)
        commit()
    }

    func commit() {
        guard !isPreview else { return }
        state.commitSettings()
    }

    func binding<T>(_ kp: WritableKeyPath<UISettings, T>, onSet: ((T) -> Void)? = nil) -> Binding<T> {
        Binding(get: { self.state.settings[keyPath: kp] },
                set: { value in
                    self.state.settings[keyPath: kp] = value
                    onSet?(value)
                    self.commit()
                })
    }
}

// MARK: - Theme

/// Colours resolved from the SwiftUI colour scheme (not dynamic NSColors), so headless renders
/// in light and dark come out exactly like the window. Values follow the concept's settings window.
struct HubTheme {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    var windowBg: Color { dark ? Color(hex: 0x1E1E20) : Color(hex: 0xECECEE) }
    var sidebarBg: Color { dark ? Color(hex: 0x262628) : Color(hex: 0xE2E2E5) }
    var sidebarPanel: Color { dark ? Color(hex: 0x2A2A2B) : Color(hex: 0xF1F1F2) }
    var sidebarPanelStroke: Color { dark ? .white.opacity(0.1) : .black.opacity(0.06) }
    var card: Color { dark ? Color(hex: 0x2A2A2D) : Color(hex: 0xF7F7F8) }
    var cardStroke: Color { dark ? .white.opacity(0.075) : .black.opacity(0.09) }
    var separator: Color { dark ? .white.opacity(0.08) : .black.opacity(0.07) }
    var windowStroke: Color { dark ? .white.opacity(0.14) : .black.opacity(0.22) }
    var fg: Color { dark ? Color(hex: 0xF5F5F7) : Color(hex: 0x1D1D1F) }
    var fg2: Color { dark ? Color(hex: 0xEBEBF5, opacity: 0.6) : Color(hex: 0x3C3C43, opacity: 0.64) }
    var fg3: Color { dark ? Color(hex: 0xEBEBF5, opacity: 0.36) : Color(hex: 0x3C3C43, opacity: 0.42) }
    var sideGroup: Color { dark ? Color(hex: 0xEBEBF5, opacity: 0.42) : Color(hex: 0x3C3C43, opacity: 0.55) }
    var sideSel: Color { dark ? .white.opacity(0.09) : .black.opacity(0.075) }
    var rowHover: Color { dark ? .white.opacity(0.05) : .black.opacity(0.035) }
    var field: Color { dark ? .white.opacity(0.08) : .black.opacity(0.05) }
    var chip: Color { dark ? .white.opacity(0.1) : .black.opacity(0.06) }
    var chipActive: Color { dark ? .white.opacity(0.18) : .black.opacity(0.12) }
    var accent: Color { Color(hex: 0x8F6CF2) }
    var ring: Color { dark ? Color(hex: 0xB89EFA) : Color(hex: 0x8F6CF2) }
    var switchOff: Color { dark ? .white.opacity(0.17) : Color(hex: 0xD4D4D9) }
    var trackOff: Color { dark ? .white.opacity(0.15) : Color(hex: 0xD6D6DB) }
    var detent: Color { dark ? .white.opacity(0.32) : .black.opacity(0.28) }
    var capsuleBg: Color { dark ? .white.opacity(0.06) : .white }
    var capsuleStroke: Color { dark ? .white.opacity(0.16) : .black.opacity(0.18) }
    var tileEdge: Color { dark ? .black.opacity(0.55) : .black.opacity(0.12) }
    var strike: Color { dark ? Color(hex: 0xFF6B6B) : Color(hex: 0xD9363E) }
    var ok: Color { Color(hex: 0x30D158) }

    func modeDot(_ m: Mode) -> Color {
        switch m {
        case .dictate: return dark ? Color(hex: 0xB89EFA) : Color(hex: 0x8F6CF2)
        case .prompt: return dark ? Color(hex: 0x6BE6D4) : Color(hex: 0x2FBFAA)
        case .command: return dark ? Color(hex: 0xFFC56B) : Color(hex: 0xE89B2E)
        case .ocr: return dark ? Color(hex: 0x8CCBFF) : Color(hex: 0x3E92F0)
        }
    }
}

private struct HubStaticKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// true while ImageRenderer draws the hub: AppKit-backed containers (ScrollView, TextField)
    /// are swapped for plain SwiftUI stand-ins that look the same.
    var hubStatic: Bool {
        get { self[HubStaticKey.self] }
        set { self[HubStaticKey.self] = newValue }
    }
}

private let hubSpring = Animation.spring(response: 0.5, dampingFraction: 0.74)

enum HubLayout {
    /// macOS 26 floats the split-view sidebar as an inset glass panel; earlier systems draw it flush.
    static var floatingSidebar: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

// MARK: - Window roots

struct HubRootView: View {
    let model: HubModel

    var body: some View {
        NavigationSplitView {
            HubSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
            HubDetail(model: model)
                .ignoresSafeArea(.container, edges: .top)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 760, minHeight: 500)
    }
}

/// The same window composed without NavigationSplitView, for headless renders.
struct HubStaticWindow: View {
    let model: HubModel
    var size = CGSize(width: 900, height: 620)
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        let shape = RoundedRectangle(cornerRadius: HubLayout.floatingSidebar ? 26 : 12, style: .continuous)
        HStack(spacing: 0) {
            if HubLayout.floatingSidebar {
                // macOS 26 draws the NavigationSplitView sidebar as a floating glass panel.
                let panel = RoundedRectangle(cornerRadius: 18, style: .continuous)
                HubSidebar(model: model)
                    .frame(width: 224)
                    .background(panel.fill(t.sidebarPanel))
                    .overlay(panel.strokeBorder(t.sidebarPanelStroke, lineWidth: 0.5))
                    .shadow(color: .black.opacity(t.dark ? 0.35 : 0.06), radius: 6, y: 1)
                    .padding([.leading, .top, .bottom], 8)
            } else {
                HubSidebar(model: model)
                    .frame(width: 224)
                    .background(t.sidebarBg)
                Rectangle().fill(t.separator).frame(width: 0.5)
            }
            HubDetail(model: model)
        }
        .frame(width: size.width, height: size.height)
        .background(t.windowBg)
        .overlay(alignment: .topLeading) { HubTrafficLights().padding(.leading, 19).padding(.top, 19) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(t.windowStroke, lineWidth: 0.5))
        .environment(\.hubStatic, true)
    }
}

struct HubTrafficLights: View {
    var body: some View {
        let d: CGFloat = HubLayout.floatingSidebar ? 14 : 12
        HStack(spacing: HubLayout.floatingSidebar ? 9 : 8) {
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { c in
                Circle().fill(Color(hex: c))
                    .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    .frame(width: d, height: d)
            }
        }
    }
}

struct HubDetail: View {
    let model: HubModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch model.pane {
            case .verlauf, .texterkennung: HubHistoryPane(model: model)
            case .woerterbuch: HubDictionaryPane(model: model)
            case .kuerzel: HubSnippetsPane(model: model)
            case .insel: HubIslandPane(model: model)
            case .welle: HubWavePane(model: model)
            case .alcove: HubAlcovePane(model: model)
            case .kontext: HubContextPane(model: model)
            case .erkennung: HubScreenTextPane(model: model)
            case .allgemein: HubGeneralPane(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(HubTheme(scheme).windowBg)
    }
}

// MARK: - Sidebar

struct HubSidebar: View {
    let model: HubModel
    @Environment(\.hubStatic) private var isStatic
    @Environment(\.colorScheme) private var scheme
    @Namespace private var ns

    var body: some View {
        let t = HubTheme(scheme)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(HubPane.top) { item($0, t) }
            Text(L("Einstellungen"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(t.sideGroup)
                .padding(.leading, 10)
                .padding(.top, 18)
                .padding(.bottom, 5)
            ForEach(HubPane.settings) { item($0, t) }
            Spacer(minLength: 12)
            footer(t)
        }
        .padding(.horizontal, 10)
        .padding(.top, HubLayout.floatingSidebar ? 44 : 52)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.pane)
        .focusable(!isStatic)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
    }

    private func step(_ d: Int) -> KeyPress.Result {
        let all = HubPane.top + HubPane.settings
        guard let i = all.firstIndex(of: model.pane) else { return .ignored }
        model.pane = all[min(max(i + d, 0), all.count - 1)]
        return .handled
    }

    private func count(_ pane: HubPane) -> String? {
        switch pane {
        case .verlauf: return model.dictationCount > 0 ? HubFormat.int(model.dictationCount) : nil
        case .texterkennung: return model.ocrCount > 0 ? HubFormat.int(model.ocrCount) : nil
        case .woerterbuch: return model.terms.isEmpty ? nil : HubFormat.int(model.terms.count)
        default: return nil
        }
    }

    private func item(_ pane: HubPane, _ t: HubTheme) -> some View {
        let selected = model.pane == pane
        return Button { model.pane = pane } label: { itemLabel(pane, selected, t) }
            .buttonStyle(HubPlainStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func itemLabel(_ pane: HubPane, _ selected: Bool, _ t: HubTheme) -> some View {
        HStack(spacing: 9) {
            HubSquircle(icon: pane.icon)
            Text(pane.title)
                .font(.system(size: 13))
                .foregroundStyle(t.fg)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let n = count(pane) {
                Text(n).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(t.fg3)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(t.sideSel)
                    .matchedGeometryEffect(id: "selection", in: ns)
            }
        }
        .contentShape(Rectangle())
    }

    private func footer(_ t: HubTheme) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(t.ok).frame(width: 7, height: 7)
                Text(L("Alles lokal und offline"))
            }
            Text(L("Nichts verlässt den Mac")).padding(.leading, 13)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(t.fg2)
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(t.separator).frame(height: 0.5) }
    }
}

struct HubSquircle: View {
    let icon: HubIcon
    var size: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Color(hex: icon.top), Color(hex: icon.bottom)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .overlay { glyph }
            .frame(width: size, height: size)
    }

    @ViewBuilder private var glyph: some View {
        if let symbol = icon.symbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        } else {
            HubNotchGlyph().frame(width: size * 0.64, height: size * 0.5)
        }
    }
}

/// A screen outline with the notch, white on the black "Insel & Kapsel" tile.
struct HubNotchGlyph: View {
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: g.size.height * 0.24, style: .continuous)
                    .strokeBorder(.white, lineWidth: 1.4)
                UnevenRoundedRectangle(bottomLeadingRadius: 1.4, bottomTrailingRadius: 1.4)
                    .fill(.white)
                    .frame(width: g.size.width * 0.38, height: g.size.height * 0.32)
            }
        }
    }
}

// MARK: - Building blocks (Alcove style)

struct HubPaneHeader<Trailing: View>: View {
    let pane: HubPane
    let trailing: Trailing
    @Environment(\.colorScheme) private var scheme

    init(pane: HubPane, @ViewBuilder trailing: () -> Trailing) {
        self.pane = pane
        self.trailing = trailing()
    }

    var body: some View {
        let t = HubTheme(scheme)
        HStack(spacing: 9) {
            HubSquircle(icon: pane.icon)
            Text(pane.headerTitle)
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(t.fg)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(t.windowBg)
        .overlay(alignment: .bottom) { Rectangle().fill(t.separator).frame(height: 0.5) }
        .zIndex(1)
    }
}

extension HubPaneHeader where Trailing == EmptyView {
    init(pane: HubPane) { self.init(pane: pane) { EmptyView() } }
}

/// ScrollView in the window, a clipped VStack in renders (ImageRenderer cannot draw NSScrollView).
struct HubScroll<Content: View>: View {
    let content: Content
    @Environment(\.hubStatic) private var isStatic

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        if isStatic {
            // Overlay so the (taller) content never pushes the pane header out of the frame.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    VStack(spacing: 0) { content }.fixedSize(horizontal: false, vertical: true)
                }
                .clipped()
        } else {
            // clipped: on macOS 26 a scroll view lets its content run up under the titlebar,
            // which is where the pane header sits
            ScrollView {
                content.frame(maxWidth: .infinity)
            }
            .clipped()
        }
    }
}

/// Settings content: one column whose left edge lines up with the pane title (20 pt), like
/// the concept's settings window where title and cards share one padding. Wide windows keep
/// the column at most 640 pt, anchored left under the title instead of centred.
struct HubSettingsColumn<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        HubScroll {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HubCard<Content: View>: View {
    let content: Content
    @Environment(\.colorScheme) private var scheme

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        let t = HubTheme(scheme)
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        VStack(spacing: 0) { content }
            .background(shape.fill(t.card))
            .clipShape(shape)
            .overlay(shape.strokeBorder(t.cardStroke, lineWidth: 0.5))
    }
}

struct HubSeparator: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle().fill(HubTheme(scheme).separator).frame(height: 0.5)
    }
}

struct HubGroupLabel: View {
    let text: String
    var top: CGFloat = 0
    @Environment(\.colorScheme) private var scheme

    init(_ text: String, top: CGFloat = 0) {
        self.text = text
        self.top = top
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(HubTheme(scheme).fg2)
            .padding(.leading, 6)
            .padding(.bottom, 7)
            .padding(.top, top)
    }
}

struct HubFootnote: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(HubTheme(scheme).fg2)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.top, 8)
    }
}

struct HubRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var dot: Color?
    var icon: NSImage?
    let trailing: Trailing
    @Environment(\.colorScheme) private var scheme

    init(_ title: String, subtitle: String? = nil, dot: Color? = nil, icon: NSImage? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.dot = dot
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        let t = HubTheme(scheme)
        HStack(spacing: 12) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            if let icon { Image(nsImage: icon).resizable().interpolation(.high).frame(width: 24, height: 24) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(t.fg)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(t.fg2)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, dot == nil ? 0 : -3)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, subtitle == nil ? 0 : 9)
        .frame(minHeight: 44)
    }
}

/// Violet switch whose knob springs over, as in the concept (overshoot like cubic-bezier(.3,1.55,.5,1)).
struct HubSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.6)) { isOn.toggle() }
        } label: {
            Capsule()
                .fill(isOn ? t.accent : t.switchOff)
                .frame(width: 36, height: 21)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .frame(width: 17, height: 17)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(HubPlainStyle())
        .accessibilityValue(isOn ? L("Ein") : L("Aus"))
    }
}

/// Value capsule with tabular digits (they never jump) but a proportional comma and space;
/// the digits roll when the value changes.
struct HubValueCapsule: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        Text(text)
            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
            .foregroundStyle(t.fg)
            .contentTransition(.numericText())
            .padding(.horizontal, 9)
            .frame(height: 23)
            .background(Capsule().fill(t.capsuleBg))
            .overlay(Capsule().strokeBorder(t.capsuleStroke, lineWidth: 0.5))
    }
}

/// Slider that rests only on detents (dots below the track) and clicks into each one.
struct HubDetentSlider: View {
    @Binding var value: Double
    let detents: [Double]
    var onCommit: () -> Void = {}
    @State private var dragging = false
    @Environment(\.colorScheme) private var scheme
    private let knob: CGFloat = 22

    private var index: Int {
        detents.indices.min { abs(detents[$0] - value) < abs(detents[$1] - value) } ?? 0
    }

    var body: some View {
        let t = HubTheme(scheme)
        GeometryReader { g in
            let usable = max(1, g.size.width - knob)
            let step = usable / CGFloat(max(1, detents.count - 1))
            let x = knob / 2 + step * CGFloat(index)
            ZStack(alignment: .topLeading) {
                Capsule().fill(t.trackOff).frame(height: 4).offset(y: knob / 2 - 2)
                Capsule().fill(t.accent).frame(width: x, height: 4).offset(y: knob / 2 - 2)
                ForEach(detents.indices, id: \.self) { i in
                    Circle().fill(t.detent)
                        .frame(width: 3, height: 3)
                        .offset(x: knob / 2 + step * CGFloat(i) - 1.5, y: knob + 4)
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                    .frame(width: knob, height: knob)
                    .scaleEffect(dragging ? 1.12 : 1)
                    .offset(x: x - knob / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging { withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { dragging = true } }
                        let i = min(max(Int(((drag.location.x - knob / 2) / step).rounded()), 0), detents.count - 1)
                        if i != index {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { value = detents[i] }
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { dragging = false }
                        onCommit()
                    })
        }
        .frame(height: knob + 9)
        .accessibilityElement()
        .accessibilityValue(HubFormat.seconds(value))
        .accessibilityAdjustableAction { dir in
            let i = index + (dir == .increment ? 1 : -1)
            guard detents.indices.contains(i) else { return }
            value = detents[i]
            onCommit()
        }
    }
}

/// No chrome, no press effect: the label is the whole control.
struct HubPlainStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

struct HubPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A small segmented switch in the hub's look (drawn in SwiftUI, so it also shows in renders,
/// which AppKit's own segmented control does not).
struct HubSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    let selection: Value
    let select: (Value) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { select(option.value) } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? t.fg : t.fg2)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(on ? (t.dark ? Color.white.opacity(0.16) : Color.white) : Color.clear)
                            .shadow(color: .black.opacity(on && !t.dark ? 0.12 : 0), radius: 1, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(t.dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)))
        .fixedSize()
    }
}

/// Tiles with live previews; the selection ring springs between them (matchedGeometryEffect).
struct HubTilePicker<Value: Hashable, Preview: View>: View {
    let options: [(value: Value, title: String)]
    let selection: Value
    let select: (Value) -> Void
    let preview: (Value) -> Preview
    @Namespace private var ns
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(options: [(value: Value, title: String)], selection: Value, select: @escaping (Value) -> Void,
         @ViewBuilder preview: @escaping (Value) -> Preview) {
        self.options = options
        self.selection = selection
        self.select = select
        self.preview = preview
    }

    var body: some View {
        let t = HubTheme(scheme)
        HStack(alignment: .top, spacing: 12) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
                Button {
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : hubSpring) { select(option.value) }
                } label: {
                    VStack(spacing: 7) {
                        preview(option.value)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .clipShape(shape)
                            .overlay(shape.strokeBorder(t.tileEdge, lineWidth: 1))
                            .matchedGeometryEffect(id: option.value, in: ns, isSource: true)
                        Text(option.title)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? t.fg : t.fg2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(HubPressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .overlay {
            // One ring for the whole picker, drawn above the tiles like the concept's .selring;
            // it springs to whichever preview is the matched source.
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(t.ring, lineWidth: 2.5)
                .padding(-4)
                .matchedGeometryEffect(id: selection, in: ns, isSource: false)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }
}

struct HubKeyCaps: View {
    let keys: [String]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(t.fg)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, k.count > 1 ? 4 : 0)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.capsuleBg))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(t.capsuleStroke, lineWidth: 0.5))
            }
        }
    }
}

struct HubChip: View {
    let title: String
    var symbol: String?
    var active = false
    /// a light tick on Force Touch trackpads when the pointer comes onto it (05.10., Nils)
    var haptic = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
                Text(title)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(t.fg)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(active ? t.chipActive : t.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(HubPressStyle())
        .onHover { inside in
            if inside && haptic { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }
}

// MARK: - Verlauf

struct HubHistoryPane: View {
    let model: HubModel
    @State private var hovered: Int64?
    @State private var expanded: Set<Int64> = []
    /// rows showing their whole text (05.10., Nils: recognized texts and unchanged dictations had
    /// no way to open beyond two lines)
    @State private var opened: Set<Int64> = []
    @State private var copied: Int64?
    @FocusState private var searchFocused: Bool
    @Environment(\.hubStatic) private var isStatic
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        VStack(spacing: 0) {
            HubPaneHeader(pane: model.ocrPane ? .texterkennung : .verlauf) { searchField(t) }
            if model.query.isEmpty ? model.totalCount > 0 : !model.entries.isEmpty { statsLine(t) }
            if model.entries.isEmpty {
                emptyState(t)
            } else {
                list(t)
            }
        }
        .onAppear(perform: consumeSearchFocus)
        .onChange(of: model.searchFocusPending) { consumeSearchFocus() }
    }

    // MARK: header

    private func searchField(_ t: HubTheme) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(t.fg3)
            if isStatic {
                Text(model.query.isEmpty ? searchPrompt : model.query)
                    .foregroundStyle(model.query.isEmpty ? t.fg3 : t.fg)
                Spacer(minLength: 0)
            } else {
                TextField("", text: Binding(get: { model.query }, set: { model.setQuery($0) }),
                          prompt: Text(searchPrompt))
                    .textFieldStyle(.plain)
                    .foregroundStyle(t.fg)
                    .focused($searchFocused)
                    .onExitCommand { model.setQuery("") }
            }
            if !model.query.isEmpty {
                Button { model.setQuery("") } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(t.fg3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Suche löschen"))
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 9)
        .frame(width: 236, height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.field))
    }

    private var searchPrompt: String {
        model.ocrPane ? L("Erkannte Texte durchsuchen") : L("Diktate durchsuchen")
    }

    private func statsLine(_ t: HubTheme) -> some View {
        let s = model.stats
        return HStack(spacing: 20) {
            if !model.query.isEmpty {
                stat(HubFormat.int(model.entries.count) + (model.canLoadMore ? "+" : ""), L("Treffer"), t)
            } else if s.count == 0 {
                Text(L("Heute noch nichts diktiert"))
                if model.totalCount > 0 { stat(HubFormat.int(model.totalCount), L("Einträge insgesamt"), t) }
            } else {
                stat(HubFormat.int(s.words), s.words == 1 ? L("Wort heute") : L("Wörter heute"), t)
                stat(HubFormat.int(s.count), s.count == 1 ? L("Diktat", context: "Anzahl") : L("Diktate"), t)
                if let avg = s.avgSeconds { stat(L("Ø %@", HubFormat.seconds(avg)), L("Verarbeitung"), t) }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(t.fg2)
        .lineLimit(1)
        .padding(.horizontal, 20)
        .frame(height: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(t.separator).frame(height: 0.5) }
    }

    private func stat(_ value: String, _ label: String, _ t: HubTheme) -> Text {
        Text("\(Text(value).fontWeight(.semibold).foregroundColor(t.fg).monospacedDigit()) \(label)")
    }

    // MARK: list

    private func list(_ t: HubTheme) -> some View {
        HubScroll {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.days) { day in
                    Text(day.label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(t.fg2)
                        .padding(.leading, 12)
                        .padding(.top, 16)
                        .padding(.bottom, 5)
                    ForEach(Array(day.items.enumerated()), id: \.element.id) { idx, entry in
                        let prev = idx > 0 ? day.items[idx - 1].id : nil
                        HubHistoryRow(
                            entry: entry,
                            hovered: isHovered(entry.id),
                            expanded: expanded.contains(entry.id) || model.previewExpanded.contains(entry.id),
                            opened: opened.contains(entry.id),
                            copied: copied == entry.id,
                            separator: prev != nil && !isHovered(entry.id) && !isHovered(prev!),
                            onHover: { inside in
                                if inside { hovered = entry.id } else if hovered == entry.id { hovered = nil }
                            },
                            onCopy: { copy(entry) },
                            onOriginal: {
                                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                                    if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                                }
                            },
                            onOpen: {
                                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                                    if opened.contains(entry.id) || expanded.contains(entry.id) {
                                        opened.remove(entry.id)
                                        expanded.remove(entry.id)
                                    } else {
                                        opened.insert(entry.id)
                                    }
                                }
                            })
                        .onAppear { if entry.id == model.entries.last?.id { model.loadMore() } }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 18)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isHovered(_ id: Int64) -> Bool { hovered == id || model.previewHover == id }

    private func consumeSearchFocus() {
        guard model.searchFocusPending else { return }
        model.searchFocusPending = false
        searchFocused = true
    }

    private func copy(_ entry: HistoryEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.final.isEmpty ? entry.raw : entry.final, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = entry.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copied == entry.id { withAnimation(.easeOut(duration: 0.2)) { copied = nil } }
        }
    }

    // MARK: empty

    private func emptyState(_ t: HubTheme) -> some View {
        VStack(spacing: 8) {
            if model.query.isEmpty && model.ocrPane {
                Text(L("Noch keine erkannten Texte"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(t.fg)
                HStack(spacing: 6) {
                    HubKeyCaps(keys: ["⇧", "⌘", "2"])
                    Text(L("drücken und einen Bereich aufziehen."))
                }
                .font(.system(size: 13))
                .foregroundStyle(t.fg2)
            } else if model.query.isEmpty {
                Text(L("Noch keine Diktate"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(t.fg)
                HStack(spacing: 6) {
                    Text(L("Halte"))
                    HubKeyCaps(keys: HubFormat.hotkey(model.state.hotkeys["dictate"] ?? "ctrl+shift"))
                    Text(L("gedrückt, sprich und lass los."))
                }
                .font(.system(size: 12.5))
                .foregroundStyle(t.fg2)
                Text(L("Jedes Diktat landet hier, durchsuchbar und nur auf diesem Mac."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(t.fg2)
            } else {
                Text(L("Keine Treffer"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(t.fg)
                Text(L("Nichts gefunden für „%@“.", model.query))
                    .font(.system(size: 12.5))
                    .foregroundStyle(t.fg2)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HubHistoryRow: View {
    let entry: HistoryEntry
    let hovered: Bool
    let expanded: Bool
    var opened = false
    let copied: Bool
    let separator: Bool
    let onHover: (Bool) -> Void
    let onCopy: () -> Void
    let onOriginal: () -> Void
    var onOpen: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    private var text: String { entry.final.isEmpty ? entry.raw : entry.final }
    /// heights of the text in full and in the closed row's two lines, at the row's width: only
    /// a row whose text is really cut can open (05.10., Nils: no Aufklappen with nothing to show)
    @State private var fullHeight: CGFloat = 0
    @State private var twoLineHeight: CGFloat = 0
    private var long: Bool { fullHeight > twoLineHeight + 1 }
    private var open: Bool { opened || expanded }
    private func measure(lines: Int?, _ done: @escaping (CGFloat) -> Void) -> some View {
        Text(text)
            .font(.system(size: 13.5))
            .lineSpacing(2.5)
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { done(g.size.height) }
                    .onChange(of: g.size.height) { _, h in done(h) }
            })
    }

    /// a Markdown table with its cells padded to the column widths (for showing only; copying
    /// keeps the Markdown that chat apps read)
    static func aligned(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        func cells(_ l: String) -> [String] {
            var t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") { t.removeLast() }
            return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let isRow = { (l: String) in l.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
        let isRule = { (l: String) in isRow(l) && l.allSatisfy { "|-: ".contains($0) } }
        var widths: [Int] = []
        for l in lines where isRow(l) && !isRule(l) {
            for (i, c) in cells(l).enumerated() {
                if i >= widths.count { widths.append(0) }
                widths[i] = max(widths[i], c.count)
            }
        }
        return lines.map { l in
            guard isRow(l) else { return l }
            if isRule(l) { return widths.map { String(repeating: "─", count: $0) }.joined(separator: "─┼─") }
            let c = cells(l)
            return widths.indices.map { i in
                let v = i < c.count ? c[i] : ""
                return v + String(repeating: " ", count: max(0, widths[i] - v.count))
            }.joined(separator: " │ ")
        }.joined(separator: "\n")
    }

    /// a recognized table: its columns line up only in a fixed-width font
    private var table: Bool { entry.mode == .ocr && text.split(separator: "\n").contains { $0.hasPrefix("|") } }
    private var hasOriginal: Bool { !entry.raw.isEmpty && !entry.final.isEmpty && HubDiff.differs(entry.raw, entry.final) }

    var body: some View {
        let t = HubTheme(scheme)
        HStack(alignment: .top, spacing: 12) {
            Text(HubFormat.time(entry.date))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(t.fg3)
                .frame(width: 36, alignment: .leading)
                .padding(.top, 2)
            HubAppIcon(name: entry.app)
                .padding(.top, -2)
            VStack(alignment: .leading, spacing: 5) {
                Text(open && table ? Self.aligned(text) : text)
                    .font(open && table ? .system(size: 12.5, design: .monospaced) : .system(size: 13.5))
                    .lineSpacing(2.5)
                    .foregroundStyle(t.fg)
                    .lineLimit(open ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(alignment: .topLeading) {
                        // the same text twice, unseen, at the same width: in full and in two lines
                        ZStack(alignment: .topLeading) {
                            measure(lines: nil) { fullHeight = $0 }
                            measure(lines: 2) { twoLineHeight = $0 }
                        }
                        .hidden()
                    }
                // No middle dots (SPEC §0): the facts are separated by spacing alone.
                HStack(spacing: 10) {
                    HubModeBadge(mode: entry.mode, formula: entry.lang == "formula")
                    if !entry.app.isEmpty { Text(entry.app) }
                    Text(HubFormat.words(entry.words))
                    if let s = entry.totalSeconds { Text(HubFormat.seconds(s)) }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(t.fg3)
                .lineLimit(1)
                if expanded && hasOriginal {
                    HubOriginalBox(raw: entry.raw, final: entry.final)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            HStack(spacing: 4) {
                HubChip(title: copied ? L("Kopiert") : L("Kopieren"), symbol: copied ? "checkmark" : nil, haptic: true, action: onCopy)
                if long { HubChip(title: open ? L("Zuklappen") : L("Aufklappen"), active: open, haptic: true, action: onOpen) }
                if hasOriginal { HubChip(title: L("Original"), active: expanded, haptic: true, action: onOriginal) }
            }
            .opacity(hovered || open ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: hovered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovered ? t.rowHover : .clear))
        .overlay(alignment: .top) {
            if separator { Rectangle().fill(t.separator).frame(height: 0.5).padding(.horizontal, 12) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if long { onOpen() } }       // a click on a long row opens or closes it
        .onHover(perform: onHover)
    }

}

struct HubModeBadge: View {
    let mode: Mode
    /// a recognized text read with ⌥ (history lang "formula"). Its "Formel" is spelled out here:
    /// the table's "Formel" is the per-app choice, "Equation" in English
    var formula = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        HStack(spacing: 5) {
            Circle().fill(t.modeDot(mode)).frame(width: 6, height: 6)
            Text(mode == .dictate ? L("Diktat") : mode == .prompt ? L("Prompt")
                 : mode == .ocr ? (formula ? (Loc.shared.english ? "Formula" : "Formel") : L("Texterkennung")) : L("Befehl"))
                .fontWeight(.semibold).foregroundStyle(t.fg2)
        }
    }
}

struct HubOriginalBox: View {
    let raw: String
    let final: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        VStack(alignment: .leading, spacing: 3) {
            Text(L("Original"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(t.fg3)
            Text(HubDiff.attributed(raw: raw, final: final, strike: t.strike))
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(t.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.field))
        .padding(.top, 4)
    }
}

/// Real app icon looked up by the app's display name; a neutral monogram when none is found.
struct HubAppIcon: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        if let image = HubAppIcons.icon(for: name) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xA1A1A6), Color(hex: 0x76767B)], startPoint: .top, endPoint: .bottom))
                .overlay { monogram }
                .padding(size * 0.09)
                .frame(width: size, height: size)
        }
    }
}

extension HubAppIcon {
    /// First letter of an unknown app, or a neutral app glyph when the app name is missing.
    @ViewBuilder fileprivate var monogram: some View {
        if let first = name.first {
            Text(String(first).capitalized)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

@MainActor
enum HubAppIcons {
    private static var cache: [String: NSImage?] = [:]
    /// Frontmost-app names arrive localised (German UI); bundles on disk carry English names.
    private static let aliases: [String: String] = [
        "Notizen": "Notes", "Nachrichten": "Messages", "Erinnerungen": "Reminders", "Kalender": "Calendar",
        "Kontakte": "Contacts", "Vorschau": "Preview", "Fotos": "Photos", "Karten": "Maps", "Musik": "Music",
        "Bücher": "Books", "Systemeinstellungen": "System Settings", "Taschenrechner": "Calculator",
        "Sprachmemos": "VoiceMemos", "Kurzbefehle": "Shortcuts", "Passwörter": "Passwords", "Uhr": "Clock",
        "Wetter": "Weather", "Aktien": "Stocks", "Schach": "Chess", "Lexikon": "Dictionary",
    ]

    static func icon(for name: String) -> NSImage? {
        guard !name.isEmpty else { return nil }
        if let hit = cache[name] { return hit }
        let found = lookup(name)
        cache[name] = found
        return found
    }

    /// at their drawn size, so AppKit keeps a small representation instead of the 1024 px one
    private static func sized(_ image: NSImage) -> NSImage {
        image.size = NSSize(width: 32, height: 32)
        return image
    }

    private static func lookup(_ name: String) -> NSImage? {
        // VoiceBud itself (a command spoken with the hub in front): its own icon. By name the
        // first match is the core, a Python process called "VoiceBud", with Python's rocket.
        if name == "VoiceBud" || name == NSRunningApplication.current.localizedName {
            return sized(NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.localizedName == name && $0.bundleIdentifier != "org.python.python" }),
           let url = app.bundleURL {
            return sized(NSWorkspace.shared.icon(forFile: url.path))
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", home + "/Applications", "/System/Library/CoreServices"]
        for candidate in [name, aliases[name]].compactMap({ $0 }) {
            for dir in dirs {
                let path = "\(dir)/\(candidate).app"
                if fm.fileExists(atPath: path) { return sized(NSWorkspace.shared.icon(forFile: path)) }
            }
        }
        return nil
    }
}

// MARK: - Wörterbuch

struct HubDictionaryPane: View {
    let model: HubModel
    @State private var draft = ""
    @State private var hovered: String?
    @State private var flash: String?
    @Environment(\.hubStatic) private var isStatic
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        VStack(spacing: 0) {
            HubPaneHeader(pane: .woerterbuch)
            HubSettingsColumn {
                Text(L("Namen und Fachbegriffe, die VoiceBud genau so schreiben soll. Ähnlich klingende Wörter ersetzt es beim Diktieren automatisch."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(t.fg2)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 16)
                HubGroupLabel(model.terms.count == 1 ? L("1 Begriff") : L("%@ Begriffe", HubFormat.int(model.terms.count)))
                HubCard {
                    addRow(t)
                    ForEach(model.terms, id: \.self) { term in
                        HubSeparator()
                        termRow(term, t)
                            .transition(.opacity)
                    }
                }
                if !learned.isEmpty {
                    HubGroupLabel(L("Gelernte Korrekturen"), top: 20)
                    HubCard {
                        ForEach(Array(learned.keys.sorted().enumerated()), id: \.element) { i, heard in
                            if i > 0 { HubSeparator() }
                            HubRow(learned[heard] ?? "", subtitle: L("statt „%@“", heard)) {
                                HubChip(title: L("Entfernen")) { forget(heard) }
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: loadLearned)
        .onChange(of: model.terms) { loadLearned() }
    }

    @State private var learned: [String: String] = [:]

    /// learned fixes from dictionary.json "replacements" (written by the core, see learn.py)
    private func loadLearned() {
        guard let data = try? Data(contentsOf: Paths.dictionary),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { learned = [:]; return }
        learned = root["replacements"] as? [String: String] ?? [:]
    }

    private func forget(_ heard: String) {
        guard let data = try? Data(contentsOf: Paths.dictionary),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var repl = root["replacements"] as? [String: String] ?? [:]
        repl.removeValue(forKey: heard)
        root["replacements"] = repl
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: Paths.dictionary, options: .atomic)
        }
        learned = repl
        IPC.send(["type": "settings_changed"])
    }

    private func addRow(_ t: HubTheme) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(t.accent)
            if isStatic {
                Text(L("Begriff hinzufügen")).foregroundStyle(t.fg3)
                Spacer(minLength: 0)
            } else {
                TextField("", text: $draft, prompt: Text(L("Begriff hinzufügen")))
                    .textFieldStyle(.plain)
                    .foregroundStyle(t.fg)
                    .onSubmit(add)
            }
            if !draft.isEmpty { HubKeyCaps(keys: ["↩"]) }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func termRow(_ term: String, _ t: HubTheme) -> some View {
        let isHovered = hovered == term || model.previewHoverTerm == term
        return HStack(spacing: 10) {
            Text(term).font(.system(size: 13)).foregroundStyle(t.fg)
            Spacer(minLength: 8)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.removeTerm(term) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(t.fg2)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(t.chip))
                    .contentShape(Circle())
            }
            .buttonStyle(HubPressStyle())
            .opacity(isHovered ? 1 : 0)
            .accessibilityLabel(L("%@ entfernen", term))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(flash == term ? t.accent.opacity(0.14) : (isHovered ? t.rowHover : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = term } else if hovered == term { hovered = nil }
        }
    }

    private func add() {
        let result = withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.addTerm(draft) }
        switch result {
        case .added(let term):
            draft = ""
            pulse(term)
        case .duplicate(let existing):
            draft = ""
            pulse(existing)
        case .empty:
            break
        }
    }

    private func pulse(_ term: String) {
        withAnimation(.easeOut(duration: 0.15)) { flash = term }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if flash == term { withAnimation(.easeOut(duration: 0.5)) { flash = nil } }
        }
    }
}

// MARK: - Settings panes

struct HubIslandPane: View {
    let model: HubModel

    var body: some View {
        let s = model.state.settings
        let shape = s.islandShape
        VStack(spacing: 0) {
            HubPaneHeader(pane: .insel)
            HubSettingsColumn {
                HubIslandStage(shape: shape, liveText: s.liveText, wave: s.waveStyle, waveLive: s.waveLive)
                    .padding(.bottom, 14)
                HubCard {
                    HubTilePicker(options: [(.insel, L("Insel an der Notch")), (.kapsel, L("Kapsel"))],
                                  selection: shape,
                                  select: { v in model.update { $0.islandStyle = v } }) { style in
                        HubIslandTile(style: style, wave: s.waveStyle, liveText: s.liveText)
                    }
                    HubSeparator()
                    HubRow(L("Live-Text beim Sprechen"),
                           subtitle: shape == .kapsel ? L("Aus: nur die Kapsel, ohne Streaming")
                                                      : L("Aus: kompakte Insel, ohne Streaming")) {
                        HubSwitch(isOn: model.binding(\.liveText))
                    }
                    HubSeparator()
                    HubRow(L("Bestätigung anzeigen")) { HubValueCapsule(text: HubFormat.seconds(s.confirmSeconds)) }
                    HubDetentSlider(value: Binding(get: { model.state.settings.confirmSeconds },
                                                   set: { model.state.settings.confirmSeconds = $0 }),
                                    detents: [0.5, 1.0, 1.5, 2.0, 2.5, 3.0],
                                    onCommit: { model.commit() })
                        .padding(.horizontal, 12)
                        .padding(.top, -4)
                        .padding(.bottom, 8)
                    HubSeparator()
                    HubRow(L("Beim Überfahren ausklappen"),
                           subtitle: L("Die Bestätigung zeigt dann den ganzen Text und bleibt offen, solange die Maus darauf ist.")) {
                        HubSwitch(isOn: model.binding(\.confirmHoverExpand))
                    }
                }
                HubFootnote(note(shape, liveText: s.liveText))
                    .transaction { $0.animation = nil }
                HubGroupLabel(L("Menüleisten-Symbol beim Aufnehmen"), top: 20)
                HubCard {
                    HubTilePicker(options: [(.schlicht, L("Schlicht")), (.farbe, L("Farbe")), (.punkt, L("Roter Punkt")), (.zeit, L("Zeit"))],
                                  selection: s.menuBarStyle,
                                  select: { v in model.update { $0.menuBarStyle = v } }) { style in
                        HubMenuBarTile(style: style)
                    }
                }
                HubFootnote(menuBarNote(s.menuBarStyle))
                    .transaction { $0.animation = nil }
            }
        }
    }

    private func menuBarNote(_ style: MenuBarStyle) -> String {
        switch style {
        case .schlicht: return L("Das Symbol bleibt immer gleich. Dass aufgenommen wird, zeigt der orange Punkt von macOS neben dem Kontrollzentrum.")
        case .farbe: return L("Das Mikrofon färbt sich in der Farbe des Modus: Diktat violett, Prompt türkis, Befehl bernstein. Bei stummem Ton steht ein durchgestrichener Lautsprecher daneben.")
        case .punkt: return L("Das Mikrofon bekommt einen kleinen roten Aufnahmepunkt, wie bei Bildschirmaufnahmen. Bei stummem Ton steht ein durchgestrichener Lautsprecher daneben.")
        case .zeit: return L("Das Symbol wird zur Kapsel mit laufender Zeit. Am auffälligsten, braucht aber mehr Platz in der Menüleiste.")
        }
    }

    /// one note per shape tile, plus one sentence for the live-text switch
    private func note(_ shape: IslandStyle, liveText: Bool) -> String {
        let base = shape == .kapsel
            ? L("Schwebt als Kapsel unter der Menüleiste. Auf Bildschirmen ohne Notch sieht VoiceBud immer so aus.")
            : L("Wächst seitlich aus der Notch. Nach dem Einfügen klappt sie kurz auf und bestätigt.")
        let live: String
        if !liveText {
            live = L("Ohne Live-Text erkennt VoiceBud erst nach dem Loslassen.")
        } else if shape == .kapsel {
            live = L("Mit Live-Text hängt beim Sprechen eine Karte mit deinem Text darunter.")
        } else {
            live = L("Mit Live-Text klappt sie beim Sprechen auf und zeigt mit, was ankommt.")
        }
        return base + " " + live
    }
}

/// A slice of the menu bar while dictating, in the chosen look (light or dark like the hub).
struct HubMenuBarTile: View {
    let style: MenuBarStyle
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let ink = dark ? Color.white.opacity(0.92) : Color.black.opacity(0.82)
        let violet = Color(hex: 0x8F6CF2)
        ZStack {
            (dark ? Color(white: 0.17) : Color(white: 0.93))
            HStack(spacing: 9) {
                switch style {
                case .schlicht:
                    Image(systemName: "mic.fill").foregroundStyle(ink)
                case .farbe:
                    Image(systemName: "mic.fill").foregroundStyle(violet)
                case .punkt:
                    Image(systemName: "mic.fill").foregroundStyle(ink)
                        .overlay(alignment: .topTrailing) {
                            Circle().fill(Color(hex: 0xFF3B30)).frame(width: 5, height: 5).offset(x: 3, y: -1)
                        }
                case .zeit:
                    HStack(spacing: 3) {
                        Image(systemName: "mic.fill").font(.system(size: 8.5, weight: .semibold))
                        Text("0:42").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(violet))
                }
                // macOS's own sign that the microphone is on, next to the Control Centre
                Circle().fill(Color.orange).frame(width: 5, height: 5)
                Text("9:41").foregroundStyle(ink)
            }
            .font(.system(size: 11.5, weight: .medium))
        }
    }
}

struct HubWavePane: View {
    let model: HubModel

    var body: some View {
        let s = model.state.settings
        VStack(spacing: 0) {
            HubPaneHeader(pane: .welle)
            HubSettingsColumn {
                HubIslandStage(shape: s.islandShape, liveText: s.liveText, wave: s.waveStyle, waveLive: s.waveLive)
                    .padding(.bottom, 14)
                HubCard {
                    HubTilePicker(options: [(.fein, L("Fein")), (.sym, L("Symmetrisch")), (.linie, L("Linie"))],
                                  selection: s.waveStyle,
                                  select: { v in model.update { $0.waveStyle = v } }) { style in
                        ZStack {
                            Color.black
                            HubWave(style: style, source: s.waveLive ? .speech : .calm, height: 18, bar: 2.5, gap: 2,
                                    seed: style == .fein ? 0.4 : (style == .linie ? 1.1 : 0))
                        }
                    }
                    HubSeparator()
                    HubRow(L("Folgt deiner Stimme live"), subtitle: L("Aus: ruhige Animation statt echtem Pegel")) {
                        HubSwitch(isOn: model.binding(\.waveLive))
                    }
                }
            }
        }
    }
}

struct HubAlcovePane: View {
    let model: HubModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = model.state.settings
        let t = HubTheme(scheme)
        let running = model.previewAlcoveRunning ?? HubSystem.alcoveRunning()
        VStack(spacing: 0) {
            HubPaneHeader(pane: .alcove)
            HubSettingsColumn {
                HubAlcoveStage(mode: s.alcove, wave: s.waveStyle, waveLive: s.waveLive)
                    .padding(.bottom, 14)
                HubCard {
                    HubRow("Alcove") {
                        HStack(spacing: 6) {
                            Circle().fill(running ? t.ok : t.fg3).frame(width: 7, height: 7)
                            Text(running ? L("Läuft gerade") : L("Läuft gerade nicht"))
                                .font(.system(size: 12.5))
                                .foregroundStyle(t.fg2)
                        }
                    }
                    HubSeparator()
                    HubTilePicker(options: [(.auto, L("Automatisch")), (.dodge, L("Ausweichen")), (.takeover, L("Übernehmen"))],
                                  selection: s.alcove,
                                  select: { v in model.update { $0.alcove = v } }) { mode in
                        HubAlcoveTile(mode: mode)
                    }
                }
                HubFootnote(s.alcove == .auto
                    ? L("VoiceBud nimmt die Notch, solange Alcove dort nichts zeigt. Spielt gerade Musik und Alcove zeigt sie an, erscheint VoiceBud als Kapsel direkt darunter. In Alcove musst du nichts umstellen.")
                    : s.alcove == .dodge
                    ? L("Alcove behält die Notch. VoiceBud erscheint als Kapsel direkt darunter, Live-Text hängt als Karte darunter. In Alcove musst du nichts umstellen.")
                    : L("Während du diktierst, gehört die Notch VoiceBud. Stell dafür in Alcove unter „Idle Activity“ auf „None“, sonst liegen zwei Inseln übereinander."))
                    .transaction { $0.animation = nil }
            }
        }
    }
}

struct HubGeneralPane: View {
    let model: HubModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        VStack(spacing: 0) {
            HubPaneHeader(pane: .allgemein)
            HubSettingsColumn {
                HubGroupLabel(L("Sprache"))
                HubCard {
                    HubRow(L("Oberfläche"), subtitle: L("Sprache von Hub, Insel, Menü und Einrichtung")) {
                        // each language in its own name, so it can be found in either language
                        HubSegmented(options: [(UILanguage.system, L("Wie macOS")), (.de, "Deutsch"), (.en, "English")],
                                     selection: model.state.settings.uiLanguage,
                                     select: { v in model.update { $0.uiLanguage = v } })
                    }
                    HubSeparator()
                    HubRow(L("Diktat"), subtitle: L("Automatisch erkennt Deutsch oder Englisch je Aufnahme")) {
                        HubSegmented(options: [(DictationLanguage.auto, L("Automatisch")), (.de, L("Deutsch")), (.en, L("Englisch"))],
                                     selection: model.state.settings.dictationLanguage,
                                     select: { v in model.update { $0.dictationLanguage = v } })
                    }
                }
                HubGroupLabel(L("Verhalten"), top: 20)
                HubCard {
                    HubRow(L("Start- und Stopp-Ton"), subtitle: L("Leiser Ton beim Drücken und beim Loslassen")) {
                        HubSwitch(isOn: model.binding(\.sounds) { on in
                            if on && !model.isPreview { HubSystem.playSample() }
                        })
                    }
                    HubSeparator()
                    HubRow(L("Im Vollbild ausblenden"), subtitle: L("Keine Insel, solange eine App im Vollbild läuft")) {
                        HubSwitch(isOn: model.binding(\.hideInFullscreen))
                    }
                    HubSeparator()
                    HubRow(L("Ton aus während der Aufnahme"), subtitle: L("Musik und Videos schweigen, solange du diktierst")) {
                        HubSwitch(isOn: model.binding(\.muteWhileRecording))
                    }
                }
                if model.state.settings.muteWhileRecording {
                    HubGroupLabel(L("Ton bleibt an bei"), top: 20)
                    HubCard {
                        let apps = model.state.settings.muteExceptions.filter { HubContextCopy.installed($0) }
                        ForEach(apps, id: \.self) { bundle in
                            HubRow(HubContextCopy.appName(bundle), icon: HubContextCopy.icon(bundle)) {
                                HubChip(title: L("Entfernen")) {
                                    model.update { $0.muteExceptions.removeAll { $0 == bundle } }
                                }
                            }
                            HubSeparator()
                        }
                        HubRow(L("Weitere App"), subtitle: L("Ist sie vorne oder spielt sie Ton (etwa ein Anruf), bleibt der Ton an.")) {
                            HubChip(title: L("App hinzufügen …")) {
                                if !model.isPreview {
                                    HubContextCopy.pickApp { bundle in
                                        model.update { s in if !s.muteExceptions.contains(bundle) { s.muteExceptions.append(bundle) } }
                                    }
                                }
                            }
                        }
                    }
                }
                HubGroupLabel(L("Speicher"), top: 20)
                HubCard {
                    HubRow(L("Modelle im RAM halten"),
                           subtitle: L("Aus spart RAM: Whisper wird nach 10 Minuten Leerlauf entladen, das Sprachmodell für die Aufbereitung nach 5 Minuten. Beide laden beim nächsten Diktat nach.")) {
                        HubSwitch(isOn: model.binding(\.keepModelsLoaded))
                    }
                }
                HubGroupLabel(L("Kurzbefehle"), top: 20)
                HubCard {
                    HubRow(L("Diktat"), dot: t.modeDot(.dictate)) {
                        HubKeyCaps(keys: HubFormat.hotkey(model.state.hotkeys["dictate"] ?? "ctrl+shift"))
                    }
                    HubSeparator()
                    HubRow(L("Prompt"), dot: t.modeDot(.prompt)) {
                        HubKeyCaps(keys: HubFormat.hotkey(model.state.hotkeys["prompt"] ?? "ctrl+alt"))
                    }
                    if let command = model.state.hotkeys["command"] {
                        HubSeparator()
                        HubRow(L("Befehl"), subtitle: L("Text markieren, halten, sagen was passieren soll"), dot: t.modeDot(.command)) {
                            HubKeyCaps(keys: HubFormat.hotkey(command))
                        }
                    }
                }
                HubFootnote(L("Diktat und Prompt: einmal drücken zum Starten, nochmal zum Beenden. Befehl: halten, sprechen, loslassen. Die Tasten legst du in config.yaml fest."))
            }
        }
    }
}

@MainActor
enum HubSystem {
    nonisolated static func alcoveInstalled() -> Bool { AlcoveProbe.installed() }

    static func alcoveRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.henrikruscon.Alcove").isEmpty
    }

    static func playSample() {
        guard let sound = NSSound(named: "Tink") else { return }
        sound.volume = 0.35
        sound.play()
    }
}

// MARK: - Previews: island, capsule, waveform

/// Notch extended in black: concave ears at the top corners, rounded bottom corners. The frame
/// width includes both ears.
struct HubIslandShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let e = max(0, min(ear, r.width / 4, r.height / 2))
        let b = max(0, min(bottom, (r.width - 2 * e) / 2, r.height - e))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addArc(center: CGPoint(x: r.minX, y: r.minY + e), radius: e,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + e, y: r.maxY - b))
        p.addArc(center: CGPoint(x: r.minX + e + b, y: r.maxY - b), radius: b,
                 startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX - e - b, y: r.maxY))
        p.addArc(center: CGPoint(x: r.maxX - e - b, y: r.maxY - b), radius: b,
                 startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        p.addArc(center: CGPoint(x: r.maxX, y: r.minY + e), radius: e,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

struct HubWallpaper: View {
    var light = false

    var body: some View {
        let stops: [Gradient.Stop] = light
            ? [.init(color: Color(hex: 0xFBE3D2), location: 0), .init(color: Color(hex: 0xEFBFAE), location: 0.38),
               .init(color: Color(hex: 0xC497B6), location: 1)]
            : [.init(color: Color(hex: 0x5A4BB0), location: 0), .init(color: Color(hex: 0x2C2470), location: 0.42),
               .init(color: Color(hex: 0x130F33), location: 1)]
        EllipticalGradient(stops: stops, center: UnitPoint(x: light ? 0.75 : 0.18, y: 0),
                           startRadiusFraction: 0, endRadiusFraction: 1.25)
    }
}

enum HubWaveSource { case speech, calm, music }

struct HubWaveColors {
    let lo: Color
    let hi: Color
    let line: Color

    static func mode(_ m: Mode) -> HubWaveColors {
        HubWaveColors(lo: Palette.accentLo(m), hi: Palette.accentHi(m), line: Palette.accent(m))
    }

    static let music = HubWaveColors(lo: Color(hex: 0xE879A8), hi: Color(hex: 0xFDE2EE), line: Color(hex: 0xF6A5C0))
}

/// Port of the concept's waveform engine: speech-like loudness (syllables ~4 Hz in 2.6 s phrases),
/// centre-weighted for "sym", a tapered line for "linie". Time-driven, so it stays calm.
enum HubWaveMath {
    static func speech(_ t: Double) -> Double {
        var p = t.truncatingRemainder(dividingBy: 3.1)
        if p < 0 { p += 3.1 }
        let gate = p < 2.6 ? min(1, p / 0.12) * min(1, (2.6 - p) / 0.18) : 0
        let syllable = 0.5 + 0.5 * sin(t * 27.0) * sin(t * 10.7 + 1.3)
        return gate * (0.15 + 0.85 * max(0, syllable))
    }

    static func envelope(_ source: HubWaveSource, _ t: Double) -> Double {
        switch source {
        case .speech: return (0..<4).reduce(0) { $0 + speech(t - Double($1) * 0.035) } / 4
        case .calm: return 0.36 + 0.2 * sin(t * 2.3) * sin(t * 0.9 + 1.1)
        case .music: return 0.55 + 0.45 * abs(sin(t * .pi * 2))
        }
    }

    static func jitter(_ i: Int, _ t: Double) -> Double {
        let d = Double(i)
        return 0.5 + 0.5 * sin(t * (3.4 + d * 0.9) + d * 2.1) * sin(t * (1.7 + d * 0.5) + d)
    }

    static func bar(_ i: Int, of n: Int, t: Double, source: HubWaveSource, sym: Bool, max h: CGFloat, min m: CGFloat) -> CGFloat {
        let c = Double(n - 1) / 2
        let d = abs(Double(i) - c)
        let shape = sym ? exp(-(d * d) / (2 * pow(c * 0.6, 2))) : 1
        let v = 0.8 * envelope(source, t) * shape * (0.5 + 0.5 * jitter(i, t))
        return m + CGFloat(v) * (h - m)
    }
}

struct HubWave: View {
    var style: WaveStyle
    var colors: HubWaveColors = .mode(.dictate)
    var source: HubWaveSource = .speech
    var height: CGFloat = 14
    var bar: CGFloat = 2
    var gap: CGFloat = 1.5
    var seed: Double = 0
    @Environment(\.hubStatic) private var isStatic

    var body: some View {
        if isStatic {
            // Renders freeze a mid-phrase moment instead of whatever instant the clock is at.
            frame(0.93 + seed * 0.02)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                frame(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000) + seed)
            }
        }
    }

    @ViewBuilder private func frame(_ t: Double) -> some View {
        if style == .linie {
            HubWaveLine(t: t, source: source)
                .stroke(colors.line, style: StrokeStyle(lineWidth: max(1, height * 1.5 / 14), lineCap: .round, lineJoin: .round))
                .frame(width: height * 24 / 14, height: height)
        } else {
            let n = style == .fein ? 4 : 7
            HStack(spacing: gap) {
                ForEach(0..<n, id: \.self) { i in
                    RoundedRectangle(cornerRadius: bar / 2)
                        .fill(LinearGradient(colors: [colors.hi, colors.lo], startPoint: .top, endPoint: .bottom))
                        .frame(width: bar, height: HubWaveMath.bar(i, of: n, t: t, source: source,
                                                                   sym: style == .sym, max: height, min: bar))
                }
            }
            .frame(height: height)
        }
    }
}

struct HubWaveLine: Shape {
    var t: Double
    var source: HubWaveSource

    func path(in r: CGRect) -> Path {
        var p = Path()
        let n = 18
        let scale = r.height / 14
        for k in 0..<n {
            let x = r.minX + CGFloat(k) / CGFloat(n - 1) * r.width
            let taper = sin(Double.pi * Double(k) / Double(n - 1))
            let amp = HubWaveMath.envelope(source, t - Double(n - k) * 0.03) * 4.2
            let off = taper * amp * sin(Double(k) * 0.95 + t * 11) * cos(Double(k) * 0.31 - t * 3.7)
            let y = min(max(r.midY + CGFloat(off) * scale, r.minY + 0.8 * scale), r.maxY - 0.8 * scale)
            if k == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

struct HubMicGlyph: View {
    var size: CGFloat = 20
    var mode: Mode = .dictate

    var body: some View {
        Circle()
            .fill(Palette.accent(mode).opacity(0.22))
            .overlay(Image(systemName: "mic.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(Palette.accent(mode)))
            .frame(width: size, height: size)
    }
}

struct HubRecDot: View {
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(Palette.rec)
            .frame(width: size, height: size)
            .background(Circle().fill(Palette.rec.opacity(0.18)).frame(width: size + 6, height: size + 6))
    }
}

/// Recording ears: mode glyph and red dot left of the hardware notch, waveform right of it.
struct HubEars<Left: View, Right: View>: View {
    var notch: CGFloat = 185
    let left: Left
    let right: Right

    init(notch: CGFloat = 185, @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.notch = notch
        self.left = left()
        self.right = right()
    }

    var body: some View {
        HStack(spacing: 6) {
            left
            Spacer(minLength: notch + 8)
            right
        }
        .padding(.horizontal, 13)
        .frame(height: 32)
    }
}

/// Recording capsule content for the previews (mic, rec dot, timer, waveform). The black
/// surface around it is drawn by the stage, so it can grow out of a tiny pill.
struct HubPillContent: View {
    var wave: WaveStyle
    var waveLive: Bool

    static let height: CGFloat = 30

    /// width of the content: paddings 7 + 13, three gaps of 8, mic 20, dot 6, timer, wave
    static func width(_ wave: WaveStyle) -> CGFloat {
        let timer = ("0:04" as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width
        let waveWidth: CGFloat
        switch wave {
        case .fein: waveWidth = 4 * 2 + 3 * 1.5
        case .sym: waveWidth = 7 * 2 + 6 * 1.5
        case .linie: waveWidth = 12 * 24 / 14
        }
        return (7 + 13 + 3 * 8 + 20 + 6 + ceil(timer) + waveWidth).rounded(.up)
    }

    var body: some View {
        HStack(spacing: 8) {
            HubMicGlyph(size: 20)
            HubRecDot()
            Text("0:04")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            HubWave(style: wave, source: waveLive ? .speech : .calm, height: 12, seed: 0.37)
        }
        .padding(.leading, 7)
        .padding(.trailing, 13)
        .frame(height: Self.height)
        .fixedSize()
    }
}

/// A preview capsule: one black surface that grows out of a 36×8 pill and shrinks back into
/// it with the island's springs (SPEC §0), fading out once it is tiny.
struct HubStageCapsule<Content: View>: View {
    let shown: Bool
    let size: CGSize
    var radius: CGFloat
    var hanging = false
    var reduce = false
    let content: Content

    init(shown: Bool, size: CGSize, radius: CGFloat, hanging: Bool = false, reduce: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.shown = shown
        self.size = size
        self.radius = radius
        self.hanging = hanging
        self.reduce = reduce
        self.content = content()
    }

    var body: some View {
        let g = shown
            ? IslandSurfaceGeometry(width: size.width, height: size.height, bottom: radius)
            : IslandSurfaceGeometry(width: IslandMetrics.seed.width, height: IslandMetrics.seed.height,
                                    bottom: IslandMetrics.seed.height / 2)
        ZStack(alignment: .top) {
            CapsuleSurfaceShape(hanging: hanging)
            ZStack(alignment: .top) {
                if shown { content.transition(.islandEnter(toward: .top, reduce: reduce)) }
            }
            .mask(alignment: .top) { CapsuleSurfaceMask() }
        }
        .islandSurface(g, widthGrowing: shown, heightGrowing: shown, reduce: reduce)
        .opacity(shown ? 1 : 0)
        .animation(shown ? .easeOut(duration: 0.12) : .easeIn(duration: 0.22).delay(0.1), value: shown)
    }
}

/// The live preview above the shape tiles. The island and the capsule morph with the same
/// springs as the real ones (SPEC §0): width 150/20 (200/20 shrinking), height and radii
/// 250/21 (250/25 shrinking); content enters with blur 10 / scaleX 0.75 and leaves with
/// blur 4 / scaleX 0.25. Kapsel: the island collapses to the bare notch while the capsule grows
/// out of a 36×8 pill below it; with live text a card hangs 6 pt under the capsule.
struct HubIslandStage: View {
    var shape: IslandStyle
    var liveText: Bool
    var wave: WaveStyle
    var waveLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 132
    private static let notch = CGSize(width: 185, height: 32)

    private var kapsel: Bool { shape == .kapsel }

    private var islandGeo: IslandSurfaceGeometry {
        if kapsel { return IslandSurfaceGeometry(width: Self.notch.width, height: Self.notch.height, top: 0, bottom: 9) }
        return liveText
            ? IslandSurfaceGeometry(width: 380, height: 86, top: 13, bottom: 24)
            : IslandSurfaceGeometry(width: 300, height: 32, top: 8, bottom: 12)
    }

    var body: some View {
        ZStack(alignment: .top) {
            HubWallpaper()
            island
            VStack(spacing: IslandMetrics.cardGap) {
                HubStageCapsule(shown: kapsel,
                                size: CGSize(width: HubPillContent.width(wave), height: HubPillContent.height),
                                radius: HubPillContent.height / 2, reduce: reduceMotion) {
                    HubPillContent(wave: wave, waveLive: waveLive)
                }
                HubStageCapsule(shown: kapsel && liveText, size: CGSize(width: 300, height: 46), radius: 16,
                                hanging: true, reduce: reduceMotion) {
                    sampleText(size: 11.5)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(width: 300, height: 46, alignment: .topLeading)
                }
            }
            .padding(.top, Self.notch.height + 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var island: some View {
        let g = islandGeo
        return ZStack(alignment: .top) {
            NotchSurfaceShape()
            VStack(alignment: .leading, spacing: 1) {
                if !kapsel {
                    ears.transition(.islandEnter(toward: .center, reduce: reduceMotion))
                }
                if !kapsel && liveText {
                    sampleText(size: 12.5)
                        .padding(.horizontal, 13)
                        .transition(.islandEnter(toward: .top, reduce: reduceMotion))
                }
            }
            .frame(width: g.width, alignment: .top)
            .mask(alignment: .top) { NotchSurfaceMask() }
        }
        .islandSurface(g, widthGrowing: !kapsel, heightGrowing: !kapsel && liveText, reduce: reduceMotion)
    }

    private var ears: some View {
        HubEars {
            HubMicGlyph()
            HubRecDot()
            if liveText {
                Text("0:09").font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                    .transition(.islandSwap(reduce: reduceMotion))
            }
        } right: {
            HubWave(style: wave, source: waveLive ? .speech : .calm)
        }
    }

    private func sampleText(size: CGFloat) -> some View {
        let old = Text(L("Den Termin am Donnerstag kann ich leider ")).foregroundColor(.white.opacity(0.5))
        let tail = Text(L("nicht wahrnehmen, nein, ich meine Freitag")).foregroundColor(.white.opacity(0.95))
        let caret = Text(" ▏").foregroundColor(Palette.accent(.dictate))
        return Text("\(old)\(tail)\(caret)")
            .font(.system(size: size))
            .lineSpacing(2)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Alcove keeps the notch (music) and VoiceBud's capsule grows out below it, or VoiceBud takes
/// the notch over. The island stays and swaps its content; the capsule grows and shrinks.
struct HubAlcoveStage: View {
    var mode: AlcoveMode
    var wave: WaveStyle
    var waveLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let width: CGFloat = 300
        ZStack(alignment: .top) {
            HubWallpaper()
            ZStack(alignment: .top) {
                NotchSurfaceShape()
                ZStack {
                    if mode == .dodge {
                        HubEars {
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(LinearGradient(colors: [Color(hex: 0xF6A5C0), Color(hex: 0x7B5CFF)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 18, height: 18)
                        } right: {
                            HubWave(style: .fein, colors: .music, source: .music, height: 12)
                        }
                        .transition(.islandSwap(reduce: reduceMotion))
                    } else {
                        HubEars {
                            HubMicGlyph()
                            HubRecDot()
                        } right: {
                            HubWave(style: wave, source: waveLive ? .speech : .calm)
                        }
                        .transition(.islandSwap(reduce: reduceMotion))
                    }
                }
                .frame(width: width)
                .mask(alignment: .top) { NotchSurfaceMask() }
            }
            .islandSurface(IslandSurfaceGeometry(width: width, height: 32, top: 8, bottom: 12),
                           widthGrowing: true, heightGrowing: true, reduce: reduceMotion)
            HubStageCapsule(shown: mode == .dodge,
                            size: CGSize(width: HubPillContent.width(wave), height: HubPillContent.height),
                            radius: HubPillContent.height / 2, reduce: reduceMotion) {
                HubPillContent(wave: wave, waveLive: waveLive)
            }
            .padding(.top, 40)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

/// Mini previews inside the shape tiles; both follow the live-text switch.
struct HubIslandTile: View {
    let style: IslandStyle
    let wave: WaveStyle
    var liveText = false

    var body: some View {
        ZStack(alignment: .top) {
            HubWallpaper(light: style == .kapsel)
            if style == .kapsel {
                VStack(spacing: 3) {
                    HStack(spacing: 4) {
                        Circle().fill(Palette.rec).frame(width: 3.5, height: 3.5)
                        HubWave(style: wave, height: 6, bar: 1.2, gap: 0.9)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 14)
                    .background(Capsule().fill(Color.black))
                    if liveText {
                        VStack(alignment: .leading, spacing: 3) {
                            Capsule().fill(.white.opacity(0.45)).frame(width: 44, height: 2)
                            HubTypingLine()
                        }
                        .padding(.horizontal, 8)
                        .frame(width: 64, height: 15, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black))
                    }
                }
                .padding(.top, liveText ? 11 : 17)
            } else if liveText {
                HubIslandShape(ear: 4, bottom: 9)
                    .fill(Color.black)
                    .frame(width: 88, height: 29)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 3) {
                            Capsule().fill(.white.opacity(0.45)).frame(width: 54, height: 2)
                            HubTypingLine()
                        }
                        .padding(.top, 14)
                        .padding(.leading, 12)
                    }
            } else {
                HubIslandShape(ear: 3, bottom: 5)
                    .fill(Color.black)
                    .frame(width: 72, height: 12)
                    .overlay {
                        HStack(spacing: 0) {
                            Circle().fill(Palette.rec).frame(width: 3.5, height: 3.5)
                            Spacer(minLength: 0)
                            HubWave(style: wave, height: 6, bar: 1.2, gap: 0.9)
                        }
                        .padding(.horizontal, 8)
                    }
            }
        }
    }
}

/// The bright second line of the live-text previews grows like text arriving.
struct HubTypingLine: View {
    @Environment(\.hubStatic) private var isStatic

    var body: some View {
        if isStatic {
            line(0.6)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                line(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6)
            }
        }
    }

    private func line(_ t: Double) -> some View {
        let eased = 1 - pow(1 - min(1, t * 1.25), 2)
        return Capsule().fill(.white).frame(width: 12 + 28 * eased, height: 2)
    }
}

struct HubAlcoveTile: View {
    let mode: AlcoveMode

    var body: some View {
        ZStack(alignment: .top) {
            HubWallpaper()
            if mode == .auto {
                HubIslandShape(ear: 3, bottom: 5)
                    .fill(Color.black)
                    .frame(width: 80, height: 12)
                    .overlay {
                        HStack(spacing: 0) {
                            Circle().fill(Palette.rec).frame(width: 3.5, height: 3.5)
                            Spacer(minLength: 0)
                            HubWave(style: .sym, height: 6, bar: 1.2, gap: 0.9)
                        }
                        .padding(.horizontal, 8)
                    }
                Capsule()
                    .strokeBorder(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                    .frame(width: 44, height: 14)
                    .padding(.top, 18)
            } else if mode == .dodge {
                HubIslandShape(ear: 3, bottom: 5)
                    .fill(Color.black)
                    .frame(width: 66, height: 12)
                    .overlay {
                        HStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(LinearGradient(colors: [Color(hex: 0xF6A5C0), Color(hex: 0x7B5CFF)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 6, height: 6)
                            Spacer(minLength: 0)
                            HubWave(style: .fein, colors: .music, source: .music, height: 6, bar: 1.2, gap: 0.9)
                        }
                        .padding(.horizontal, 7)
                    }
                HStack(spacing: 4) {
                    Circle().fill(Palette.rec).frame(width: 3.5, height: 3.5)
                    HubWave(style: .sym, height: 6, bar: 1.2, gap: 0.9)
                }
                .padding(.horizontal, 8)
                .frame(height: 14)
                .background(Capsule().fill(.black.opacity(0.9)))
                .padding(.top, 18)
            } else {
                HubIslandShape(ear: 3, bottom: 5)
                    .fill(Color.black)
                    .frame(width: 80, height: 12)
                    .overlay {
                        HStack(spacing: 0) {
                            Circle().fill(Palette.rec).frame(width: 3.5, height: 3.5)
                            Spacer(minLength: 0)
                            HubWave(style: .sym, height: 6, bar: 1.2, gap: 0.9)
                        }
                        .padding(.horizontal, 8)
                    }
            }
        }
    }
}

// MARK: - Helpers

/// L() for a German word the hub uses in two senses that English tells apart ("Diktat" is the
/// mode and, in the stats line, "1 dictation"). The English table carries the second sense as
/// "<German> (<context>)"; without that entry it falls back to L(german). German is unchanged.
func L(_ german: String, context: String) -> String {
    Loc.shared.english ? (Loc.en["\(german) (\(context))"] ?? L(german)) : german
}

/// Numbers and dates in the app's language: "1.284", "0,7 s", "Montag, 5. Oktober" in German,
/// "1,284", "0.7 s", "Monday, October 5" in English. Times stay 24-hour in both (the column is
/// sized for "09:41").
enum HubFormat {
    private static let de = Locale(identifier: "de_DE")
    private static let en = Locale(identifier: "en_US")

    private static func intFormatter(_ locale: Locale) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        return f
    }

    private static func formatter(_ format: String, _ locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = format
        return f
    }

    private static let intDE = intFormatter(de), intEN = intFormatter(en)
    private static let timeDE = formatter("HH:mm", de), timeEN = formatter("HH:mm", en)
    private static let dayDE = formatter("EEEE, d. MMMM", de), dayEN = formatter("EEEE, MMMM d", en)
    private static let yearDE = formatter("d. MMMM yyyy", de), yearEN = formatter("MMMM d, yyyy", en)

    private static var english: Bool { Loc.shared.english }

    static func int(_ n: Int) -> String { (english ? intEN : intDE).string(from: NSNumber(value: n)) ?? "\(n)" }

    static func seconds(_ s: Double) -> String {
        let text = String(format: "%.1f s", s)
        return english ? text : text.replacingOccurrences(of: ".", with: ",")
    }

    static func words(_ n: Int) -> String { n == 1 ? L("1 Wort") : L("%@ Wörter", int(n)) }

    static func time(_ d: Date) -> String { (english ? timeEN : timeDE).string(from: d) }

    static func dayLabel(_ day: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return L("Heute") }
        if cal.isDateInYesterday(day) { return L("Gestern") }
        let thisYear = cal.isDate(day, equalTo: now, toGranularity: .year)
        return (thisYear ? (english ? dayEN : dayDE) : (english ? yearEN : yearDE)).string(from: day)
    }

    /// "ctrl+shift" -> ["⌃", "⇧"]; plain names and _l/_r variants as in config.yaml.
    static func hotkey(_ spec: String) -> [String] {
        spec.split(separator: "+").map { part in
            let k = part.trimmingCharacters(in: .whitespaces).lowercased()
            let base = k.hasSuffix("_l") || k.hasSuffix("_r") ? String(k.dropLast(2)) : k
            switch base {
            case "ctrl", "control": return "⌃"
            case "shift": return "⇧"
            case "alt", "option", "opt": return "⌥"
            case "cmd", "command": return "⌘"
            case "fn": return "fn"
            default: return base.capitalized
            }
        }
    }
}

/// Word diff between the raw transcript and the cleaned final text (LCS on normalised words).
enum HubDiff {
    private static func normalize<S: StringProtocol>(_ w: S) -> String {
        w.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    static func differs(_ raw: String, _ final: String) -> Bool {
        let a = raw.split(whereSeparator: \.isWhitespace).map(normalize).filter { !$0.isEmpty }
        let b = final.split(whereSeparator: \.isWhitespace).map(normalize).filter { !$0.isEmpty }
        return a != b
    }

    /// Every word of `raw`, flagged whether it survived into `final`.
    static func marks(raw: String, final: String) -> [(word: String, kept: Bool)] {
        let r = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let rn = r.map(normalize)
        let f = final.split(whereSeparator: \.isWhitespace).map(normalize).filter { !$0.isEmpty }
        let n = rn.count, m = f.count
        guard n > 0, m > 0, n * m <= 1_500_000 else { return r.map { ($0, true) } }
        var dp = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        let w = m + 1
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i * w + j] = (!rn[i].isEmpty && rn[i] == f[j])
                    ? dp[(i + 1) * w + j + 1] + 1
                    : max(dp[(i + 1) * w + j], dp[i * w + j + 1])
            }
        }
        var out: [(word: String, kept: Bool)] = []
        var i = 0, j = 0
        while i < n {
            if rn[i].isEmpty {
                out.append((r[i], true)); i += 1
            } else if j < m && rn[i] == f[j] {
                out.append((r[i], true)); i += 1; j += 1
            } else if j < m && dp[i * w + j + 1] >= dp[(i + 1) * w + j] {
                j += 1
            } else {
                out.append((r[i], false)); i += 1
            }
        }
        return out
    }

    static func attributed(raw: String, final: String, strike: Color) -> AttributedString {
        let marks = marks(raw: raw, final: final)
        var s = AttributedString()
        for (k, mark) in marks.enumerated() {
            var part = AttributedString(mark.word)
            if !mark.kept {
                part.strikethroughStyle = .single
                part.foregroundColor = strike
            }
            s += part
            if k < marks.count - 1 { s += AttributedString(" ") }
        }
        return s
    }
}


// MARK: - Bildschirmkontext (KONTEXT-PLAN.md)

enum HubContextCopy {
    // computed, not stored: the titles follow a language switch
    static var levels: [(value: Int, title: String)] {
        [(0, L("Aus")), (1, L("Nur App")), (2, L("Text am Cursor")), (3, L("Ganzes Fenster"))]
    }

    static func hint(_ level: Int) -> String {
        switch level {
        case 0: return L("VoiceBud liest nichts vom Bildschirm.")
        case 1: return L("VoiceBud sieht nur, in welcher App du schreibst, und wählt danach den Stil.")
        case 3: return L("Dazu der sichtbare Text im aktiven Fenster, etwa ein Chatverlauf. So stimmen auch Namen aus dem Gespräch.")
        default: return L("Empfohlen. Dazu der Text vor und nach dem Cursor, markierter Text sowie Empfänger und Betreff. So stimmen Namen, Anrede und Anschluss.")
        }
    }

    static var perApp: [(value: Int, title: String)] { [(0, L("Aus")), (2, L("Cursor")), (3, L("Fenster"))] }

    /// same list as context.DEFAULT_APP_LEVELS: chats and AI chats read the whole window
    static let windowByDefault = ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.MobileSMS", "ru.keepcoder.Telegram",
        "org.telegram.desktop", "org.whispersystems.signal-desktop", "com.hnc.Discord",
        "com.anthropic.claudefordesktop", "com.openai.chat"]

    static func installed(_ bundle: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil
    }

    /// the level an app gets without an own choice
    static func standard(_ bundle: String, base: Int) -> Int {
        base == 2 && windowByDefault.contains { $0.lowercased() == bundle.lowercased() } ? 3 : base
    }

    private static var icons: [String: NSImage] = [:]

    static func icon(_ bundle: String) -> NSImage? {
        if let hit = icons[bundle] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 32, height: 32)
        icons[bundle] = image
        return image
    }

    /// "App hinzufügen": pick an app in /Applications, it starts on "Ganzes Fenster"
    @MainActor static func addApp(_ model: HubModel) {
        pickApp { bundle in model.update { $0.contextApps[bundle] = 3 } }
    }

    @MainActor static func pickApp(_ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Hinzufügen")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url, let bundle = Bundle(url: url)?.bundleIdentifier else { return }
            done(bundle)
        }
    }

    static func appName(_ bundle: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Texterkennung settings (05.10., Nils: out of Allgemein, into a category of their own):
/// ⇧⌘2 on or off, its history, the formulas and what each app gets.
struct HubScreenTextPane: View {
    let model: HubModel

    var body: some View {
        VStack(spacing: 0) {
            HubPaneHeader(pane: .erkennung)
            HubSettingsColumn {
                HubCard {
                    HubRow(L("Texterkennung mit ⇧⌘2"), subtitle: L("Bereich aufziehen, der Text landet in der Zwischenablage")) {
                        HubSwitch(isOn: model.binding(\.screenText))
                    }
                    HubSeparator()
                    HubRow(L("Erkannte Texte im Verlauf"), subtitle: L("Eigener Verlauf, getrennt von den Diktaten")) {
                        HubSwitch(isOn: model.binding(\.screenTextHistory))
                    }
                }
                if model.state.settings.screenText {
                    HubGroupLabel(L("Formeln"), top: 20)
                    HubCard {
                        HubRow(L("Schrift in Word anpassen"),
                               subtitle: L("Der Text um die Formeln nimmt die Schrift an deinem Cursor. macOS fragt dafür einmal, ob VoiceBud Word steuern darf.")) {
                            HubSwitch(isOn: model.binding(\.wordFontFromCursor))
                        }
                        HubSeparator()
                        HubRow(L("⌥ antippen beim Aufziehen"),
                               subtitle: L("Nach ⇧⌘2 schaltet ⌥ zwischen Text und Formeln um, die Insel zeigt, was gilt. Brüche, Hochzahlen, Wurzeln und der Text drumherum, gelesen vom lokalen Sprachmodell.")) {
                            EmptyView()
                        }
                    }
                    HubFormulaApps(model: model)
                }
            }
        }
    }
}

/// Formulas per app (05.10., Nils): what a formula read with ⌥ becomes when pasted there.
/// The usual apps that are installed, plus every app with an own choice; more via "App hinzufügen".
struct HubFormulaApps: View {
    let model: HubModel
    @Environment(\.colorScheme) private var scheme

    /// the apps formulas usually go to, in groups: writing, AI chats, browsers, notes, Office,
    /// messengers (05.10., Nils missed WhatsApp). Only the installed ones are listed; every other
    /// app gets its standard and can be added.
    static let usual = [
        "com.microsoft.Word", "com.apple.iWork.Pages", "com.apple.Notes", "com.apple.mail", "com.apple.TextEdit",
        "com.anthropic.claudefordesktop", "com.openai.chat", "ai.perplexity.mac",
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "company.thebrowser.dia",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
        "notion.id", "md.obsidian", "net.shinyfrog.bear",
        "com.microsoft.Powerpoint", "com.microsoft.onenote.mac", "com.microsoft.Outlook",
        "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2", "com.hnc.Discord", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "org.whispersystems.signal-desktop",
    ]

    private func rows(_ s: UISettings) -> [String] {
        let usual = model.isPreview
            ? ["com.microsoft.Word", "com.apple.Notes", "com.anthropic.claudefordesktop", "com.apple.Safari"]
            : Self.usual.filter { HubContextCopy.installed($0) }
        let own = s.formulaApps.keys.filter { k in !usual.contains { $0.lowercased() == k.lowercased() } }
        return usual + own.sorted()
    }

    /// (computed: the titles follow a language switch)
    static var options: [(value: ScreenText.FormulaTarget, title: String)] {
        [(.latex, "LaTeX"), (.equations, L("Formel")), (.characters, L("Zeichen"))]
    }

    var body: some View {
        let s = model.state.settings
        let t = HubTheme(scheme)
        HubGroupLabel(L("Formeln je App"), top: 20)
        HubCard {
            ForEach(rows(s), id: \.self) { bundle in
                HubRow(HubContextCopy.appName(bundle),
                       subtitle: s.formulaApps[bundle] == nil ? L("Standard") : L("Eigene Wahl"),
                       icon: HubContextCopy.icon(bundle)) {
                    HStack(spacing: 10) {
                        if s.formulaApps[bundle] != nil {
                            Button(L("Zurücksetzen")) { model.update { $0.formulaApps.removeValue(forKey: bundle) } }
                                .buttonStyle(.plain)
                                .font(.system(size: 12.5))
                                .foregroundStyle(t.fg2)
                        }
                        let current = ScreenText.formulaTarget(bundle, own: s.formulaApps)
                        HStack(spacing: 4) {
                            ForEach(Self.options, id: \.value) { option in
                                HubChip(title: option.title, active: current == option.value) {
                                    model.update { $0.formulaApps[bundle] = option.value.rawValue }
                                }
                            }
                        }
                    }
                }
                HubSeparator()
            }
            HubRow(L("Weitere App"), subtitle: L("Eine App aus dem Programme-Ordner auswählen und festlegen, was dort ankommt.")) {
                HubChip(title: L("App hinzufügen …")) {
                    if !model.isPreview {
                        HubContextCopy.pickApp { bundle in
                            model.update { s in
                                if s.formulaApps[bundle] == nil {
                                    s.formulaApps[bundle] = ScreenText.formulaStandard(bundle).rawValue
                                }
                            }
                        }
                    }
                }
            }
        }
        HubFootnote(L("LaTeX für Apps, die Formeln selbst setzen, etwa Claude, ChatGPT oder Overleaf im Browser. Formel wird zur echten, bearbeitbaren Formel, getestet mit Word. Zeichen geht überall, etwa σ² oder √(x + 1)."))
    }
}

struct HubContextPane: View {
    let model: HubModel
    @Environment(\.colorScheme) private var scheme

    /// the usual apps that are installed, as in "Formeln je App" (05.10., Nils: Word, Notizen or
    /// the browsers were missing, only the chat apps that read the whole window were listed), plus
    /// every app with an own choice
    private func appRows(_ s: UISettings) -> [String] {
        let usual = HubFormulaApps.usual + HubContextCopy.windowByDefault.filter { !HubFormulaApps.usual.contains($0) }
        let defaults = model.isPreview
            ? ["com.microsoft.Word", "com.apple.mail", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp",
               "com.anthropic.claudefordesktop"]
            : usual.filter { HubContextCopy.installed($0) }
        let own = s.contextApps.keys.filter { k in !defaults.contains { $0.lowercased() == k.lowercased() } }
        return defaults + own.sorted()
    }

    var body: some View {
        let s = model.state.settings
        let t = HubTheme(scheme)
        VStack(spacing: 0) {
            HubPaneHeader(pane: .kontext)
            HubSettingsColumn {
                HubCard {
                    HubTilePicker(options: HubContextCopy.levels, selection: s.contextLevel,
                                  select: { v in model.update { $0.contextLevel = v } }) { level in
                        HubContextTile(level: level)
                    }
                }
                HubFootnote(HubContextCopy.hint(s.contextLevel))
                    .transaction { $0.animation = nil }
                HubGroupLabel(L("Im Prompt-Modus"))
                    .padding(.top, 16)
                HubCard {
                    HubRow(L("„Diese Mail“ dazusagen"),
                           subtitle: L("Sagst du „diese Mail“, „dieser Text“ oder „das hier“, liest VoiceBud für dieses eine Diktat das ganze Fenster und hängt den Text wörtlich unter den Prompt. Markierter Text kommt immer mit.")) {
                        EmptyView()
                    }
                }
                HubGroupLabel(L("Apps"))
                    .padding(.top, 16)
                HubCard {
                    HubRow(L("Electron-Apps freischalten"),
                           subtitle: L("Claude, Slack und Co. zeigen ihren Text erst, wenn VoiceBud sie beim Wechsel nach vorne freischaltet.")) {
                        HubSwitch(isOn: model.binding(\.contextElectron))
                    }
                    ForEach(appRows(s), id: \.self) { bundle in
                        HubSeparator()
                        HubRow(HubContextCopy.appName(bundle),
                               subtitle: s.contextApps[bundle] == nil ? L("Standard") : L("Eigene Wahl"),
                               icon: HubContextCopy.icon(bundle)) {
                            HStack(spacing: 10) {
                                if s.contextApps[bundle] != nil {
                                    Button(L("Zurücksetzen")) { model.update { $0.contextApps.removeValue(forKey: bundle) } }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(t.fg2)
                                }
                                let current = s.contextApps[bundle] ?? HubContextCopy.standard(bundle, base: s.contextLevel)
                                HStack(spacing: 4) {
                                    ForEach(HubContextCopy.perApp, id: \.value) { option in
                                        HubChip(title: option.title, active: current == option.value) {
                                            model.update { $0.contextApps[bundle] = option.value }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    HubSeparator()
                    HubRow(L("Weitere App"), subtitle: L("Eine App aus dem Programme-Ordner auswählen. Sie liest dann das ganze Fenster.")) {
                        HubChip(title: L("App hinzufügen …")) {
                            if !model.isPreview { HubContextCopy.addApp(model) }
                        }
                    }
                    HubSeparator()
                    HubRow(L("Immer ausgenommen"),
                           subtitle: L("Passwörter, Schlüsselbund, 1Password, Bitwarden und VoiceBud selbst, dazu Passwortfelder, sichere Eingabe und private Fenster.")) {
                        EmptyView()
                    }
                }
                HubFootnote(L("Alles bleibt auf diesem Mac und wird nach dem Einfügen sofort verworfen. Im Verlauf steht nie, was VoiceBud gelesen hat."))
            }
        }
    }
}

/// A tiny window: what the level reads is drawn in the accent colour.
struct HubContextTile: View {
    let level: Int

    var body: some View {
        let accent = Palette.accent(.dictate)
        let dim = Color.black.opacity(0.18)
        ZStack {
            HubWallpaper()
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(level >= 1 ? accent : dim).frame(width: 34, height: 4)
                RoundedRectangle(cornerRadius: 1.5).fill(level >= 3 ? accent.opacity(0.7) : dim).frame(width: 58, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(level >= 3 ? accent.opacity(0.7) : dim).frame(width: 46, height: 3)
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1.5).fill(level >= 2 ? accent : dim).frame(width: 30, height: 3)
                    Rectangle().fill(level >= 2 ? accent : Color.black.opacity(0.35)).frame(width: 1, height: 7)
                    RoundedRectangle(cornerRadius: 1.5).fill(level >= 2 ? accent : dim).frame(width: 18, height: 3)
                }
            }
            .padding(8)
            .frame(width: 76, height: 46, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.92)))
        }
    }
}


// MARK: - Kürzel (snippets.py)

struct HubSnippetsPane: View {
    let model: HubModel
    @State private var items: [[String: String]] = []
    @State private var trigger = ""
    @State private var text = ""
    @Environment(\.hubStatic) private var isStatic
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = HubTheme(scheme)
        VStack(spacing: 0) {
            HubPaneHeader(pane: .kuerzel)
            HubSettingsColumn {
                Text(L("Sag den Auslöser beim Diktieren, und VoiceBud setzt den ganzen Text wörtlich ein, etwa deine Adresse oder Signatur."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(t.fg2)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 16)
                HubCard {
                    VStack(alignment: .leading, spacing: 8) {
                        field(L("Wenn ich sage"), L("meine Signatur"), $trigger, t)
                        HStack(alignment: .top, spacing: 10) {
                            Text(L("schreibt VoiceBud")).font(.system(size: 12.5)).foregroundStyle(t.fg2).frame(width: 118, alignment: .leading)
                            if isStatic {
                                Text(L("Viele Grüße\nDein Name")).font(.system(size: 13)).foregroundStyle(t.fg3)
                                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                            } else {
                                TextEditor(text: $text)
                                    .font(.system(size: 13))
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 54, maxHeight: 110)
                            }
                        }
                        HStack {
                            Spacer()
                            HubChip(title: L("Hinzufügen"), active: canAdd) { add() }
                                .disabled(!canAdd)
                        }
                    }
                    .padding(12)
                }
                let shown = isStatic ? model.previewSnippets : items
                HubGroupLabel(shown.count == 1 ? L("1 Kürzel") : L("%d Kürzel", shown.count), top: 20)
                HubCard {
                    if shown.isEmpty {
                        Text(L("Noch keine Kürzel."))
                            .font(.system(size: 13)).foregroundStyle(t.fg3)
                            .padding(.horizontal, 12).frame(height: 44, alignment: .leading)
                    }
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, item in
                        if i > 0 { HubSeparator() }
                        HubRow(item["trigger"] ?? "", subtitle: (item["text"] ?? "").replacingOccurrences(of: "\n", with: "  ")) {
                            HubChip(title: L("Entfernen")) { remove(i) }
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    private var canAdd: Bool {
        !trigger.trimmingCharacters(in: .whitespaces).isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func field(_ label: String, _ placeholder: String, _ value: Binding<String>, _ t: HubTheme) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(t.fg2).frame(width: 118, alignment: .leading)
            if isStatic {
                Text(placeholder).font(.system(size: 13)).foregroundStyle(t.fg3)
                Spacer(minLength: 0)
            } else {
                TextField("", text: value, prompt: Text(placeholder)).textFieldStyle(.plain).font(.system(size: 13))
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.snippets),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["snippets"] as? [[String: String]] else { items = []; return }
        items = list
    }

    private func add() {
        guard canAdd else { return }
        items.append(["trigger": trigger.trimmingCharacters(in: .whitespaces),
                      "text": text.trimmingCharacters(in: .whitespacesAndNewlines)])
        trigger = ""
        text = ""
        model.state.commitSnippets(items)
    }

    private func remove(_ i: Int) {
        guard items.indices.contains(i) else { return }
        items.remove(at: i)
        model.state.commitSnippets(items)
    }
}
