import CoreGraphics
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
