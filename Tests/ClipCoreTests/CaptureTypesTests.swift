import CoreGraphics
import Foundation
import Testing
@testable import ClipCore

@Test func captureRegionStandardizesAndValidates() {
    let region = CaptureRegion(rect: CGRect(x: 20, y: 30, width: -12, height: -16))

    #expect(region.rect == CGRect(x: 8, y: 14, width: 12, height: 16))
    #expect(region.isUsable)
}

@Test func tinyCaptureRegionIsRejected() {
    #expect(!CaptureRegion(rect: CGRect(x: 0, y: 0, width: 7, height: 20)).isUsable)
}

@Test func captureFailuresUseUserLanguageWithoutDiagnosticPaths() {
    let messages = [
        ClipError.captureFailed,
        .unstableContent,
        .stitchConfidenceTooLow,
        .outputTooLarge,
        .processingTimedOut
    ].compactMap(\.errorDescription)

    #expect(messages.allSatisfy { !$0.contains("Caches") })
    #expect(messages.allSatisfy { !$0.contains("分片") })
    #expect(messages.allSatisfy { !$0.contains("置信度") })
}

@Test func noScrollFeedbackExplainsHowToRecoverInBothLanguages() {
    #expect(
        ScrollingCaptureFeedback.noMovementMessage(language: .english)
            == "The selected area did not scroll. Place the pointer inside it, scroll the content, then click Done."
    )
    #expect(
        ScrollingCaptureFeedback.noMovementMessage(language: .simplifiedChinese)
            == "所选区域没有发生滚动。请将鼠标移入选区，滚动内容后再点“完成”。"
    )
}

@Test func scrollingPromptSeparatesTheNextStepFromTheFinishAction() {
    #expect(
        ScrollingCaptureFeedback.instruction(language: .english)
            == "Scroll the selected area"
    )
    #expect(
        ScrollingCaptureFeedback.instruction(language: .simplifiedChinese)
            == "滚动选区内容"
    )
    #expect(ScrollingCaptureFeedback.doneTitle(language: .english) == "Done")
    #expect(ScrollingCaptureFeedback.doneTitle(language: .simplifiedChinese) == "完成")
}

@Test func languageFollowsTheFirstSystemPreference() {
    #expect(
        ClipLanguagePreferences.language(for: ["zh-Hans-CN", "en-US"])
            == .simplifiedChinese
    )
    #expect(
        ClipLanguagePreferences.language(for: ["en-US", "zh-Hans-CN"])
            == .english
    )
    #expect(
        ClipLanguagePreferences.language(for: ["zh-CN", "en-US"])
            == .simplifiedChinese
    )
    #expect(
        ClipLanguagePreferences.language(for: ["zh-Hant-TW", "zh-Hans-CN"])
            == .english
    )
    #expect(ClipLanguagePreferences.language(for: ["ja-JP"]) == .english)
    #expect(ClipLanguagePreferences.language(for: ["ko-KR"]) == .english)
    #expect(ClipLanguagePreferences.language(for: ["fr-FR"]) == .english)
    #expect(ClipLanguagePreferences.language(for: []) == .english)
}
