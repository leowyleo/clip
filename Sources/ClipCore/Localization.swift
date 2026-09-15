import Foundation

public enum ClipLanguage: String, CaseIterable, Sendable {
    case english
    case simplifiedChinese
}

public extension Notification.Name {
    static let clipLanguageDidChange = Notification.Name("cc.clip.mac.languageChanged")
}

public enum ClipLanguagePreferences {
    public static let languageKey = "cc.clip.mac.language"

    public static var language: ClipLanguage {
        get { language(in: .standard) }
        set {
            let previous = language(in: .standard)
            setLanguage(newValue, in: .standard)
            guard previous != newValue else { return }
            NotificationCenter.default.post(name: .clipLanguageDidChange, object: nil)
        }
    }

    public static func language(in defaults: UserDefaults) -> ClipLanguage {
        guard let stored = defaults.string(forKey: languageKey),
              let language = ClipLanguage(rawValue: stored) else {
            return .english
        }
        return language
    }

    public static func setLanguage(
        _ language: ClipLanguage,
        in defaults: UserDefaults
    ) {
        defaults.set(language.rawValue, forKey: languageKey)
    }
}

public enum ClipLocalization {
    public static func text(
        _ english: String,
        _ simplifiedChinese: String,
        language: ClipLanguage = ClipLanguagePreferences.language
    ) -> String {
        switch language {
        case .english:
            english
        case .simplifiedChinese:
            simplifiedChinese
        }
    }
}

public enum ScrollingCaptureFeedback {
    public static func noMovementMessage(
        language: ClipLanguage = ClipLanguagePreferences.language
    ) -> String {
        ClipLocalization.text(
            "The selected area did not scroll. Place the pointer inside it, scroll the content, then click Done.",
            "所选区域没有发生滚动。请将鼠标移入选区，滚动内容后再点“完成”。",
            language: language
        )
    }

    public static func instruction(
        language: ClipLanguage = ClipLanguagePreferences.language
    ) -> String {
        ClipLocalization.text(
            "Scroll the selected area",
            "滚动选区内容",
            language: language
        )
    }

    public static func doneTitle(
        language: ClipLanguage = ClipLanguagePreferences.language
    ) -> String {
        ClipLocalization.text("Done", "完成", language: language)
    }
}
