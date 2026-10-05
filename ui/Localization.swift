// The app's own language (05.10., Nils): German or English, as macOS or fixed in the hub. Every
// text is written in German in the code and wrapped in L(); in English it is looked up in the
// tables of Strings+*.swift (a missing entry falls back to the German text). Switching needs no
// restart: Loc is observable, so every view that called L() redraws.
import Foundation
import Observation

@Observable
final class Loc: @unchecked Sendable {   // written on the main thread only, when the setting changes
    static let shared = Loc()
    /// "de" or "en", resolved from the setting
    private(set) var lang = "de"
    /// VOICEBUD_UI_LANG=en|de: renders and tests in one language, whatever the setting says
    private let forced: String? = {
        let v = ProcessInfo.processInfo.environment["VOICEBUD_UI_LANG"]
        return v == "de" || v == "en" ? v : nil
    }()

    init() { if let forced { lang = forced } }

    func apply(_ setting: UILanguage) {
        if forced != nil { return }
        let resolved: String
        switch setting {
        case .de: resolved = "de"
        case .en: resolved = "en"
        case .system: resolved = Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"
        }
        if resolved != lang { lang = resolved }
    }

    var english: Bool { lang == "en" }

    /// German text -> English, from every part of the app
    nonisolated static let en: [String: String] = {
        var all: [String: String] = [:]
        for part in [hub, onboarding, island] { all.merge(part) { first, _ in first } }
        return all
    }()
}

/// A text of the app in the current language. `args` fill %@ / %d placeholders like
/// String(format:), in both languages.
func L(_ german: String, _ args: CVarArg...) -> String {
    let text = Loc.shared.english ? (Loc.en[german] ?? german) : german
    return args.isEmpty ? text : String(format: text, arguments: args)
}
