import Foundation

public enum ClipLanguage: String, CaseIterable, Sendable {
    case english
    case simplifiedChinese
}

public enum ClipLanguagePreferences {
    /// Resolves Clip's UI from the first macOS preferred language only.
    /// Simplified Chinese is the only non-English UI shipped for now.
    public static var language: ClipLanguage {
        language(for: Locale.preferredLanguages)
    }

    public static func language(for preferredLanguages: [String]) -> ClipLanguage {
        guard let preferred = preferredLanguages.first else {
            return .english
        }

        let identifier = preferred
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let isSimplifiedChinese = identifier == "zh-hans"
            || identifier.hasPrefix("zh-hans-")
            || identifier == "zh-cn"
            || identifier.hasPrefix("zh-cn-")
            || identifier == "zh-sg"
            || identifier.hasPrefix("zh-sg-")
        return isSimplifiedChinese ? .simplifiedChinese : .english
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
