import CoreGraphics
import Foundation

public enum CaptureMode: Sendable {
    case region
    case scrolling
}

public struct CaptureRegion: Equatable, Sendable {
    public var rect: CGRect

    public init(rect: CGRect) {
        self.rect = rect.standardized
    }

    public var isUsable: Bool {
        rect.width >= 8 && rect.height >= 8
    }
}

public enum ClipError: LocalizedError, Equatable, Sendable {
    case screenRecordingPermissionDenied
    case invalidSelection
    case captureFailed
    case protectedContent
    case noScrollableContent
    case unstableContent
    case stitchConfidenceTooLow
    case outputTooLarge
    case processingTimedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            ClipLocalization.text(
                "Allow Clip to capture the selected screen content.",
                "请允许 Clip 读取所选屏幕内容。"
            )
        case .invalidSelection:
            ClipLocalization.text(
                "Select a larger capture area.",
                "请选择更大的截图区域。"
            )
        case .captureFailed:
            ClipLocalization.text(
                "The capture could not be completed. No image was created.",
                "这次截图没有完成，未生成图片。"
            )
        case .protectedContent:
            ClipLocalization.text(
                "This content is protected by the system and cannot be captured.",
                "此内容受系统保护，无法截取。"
            )
        case .noScrollableContent:
            ClipLocalization.text(
                "No additional content was detected.",
                "没有检测到更多内容。"
            )
        case .unstableContent:
            ClipLocalization.text(
                "The content kept changing. No image was created.",
                "画面持续变化，这次没有生成图片。"
            )
        case .stitchConfidenceTooLow:
            ClipLocalization.text(
                "The content did not remain continuous. No image was created.",
                "画面没有保持连续，这次没有生成图片。"
            )
        case .outputTooLarge:
            ClipLocalization.text(
                "The safe length limit was reached. No image was created.",
                "已达到安全长度，这次没有生成图片。"
            )
        case .processingTimedOut:
            ClipLocalization.text(
                "Processing took too long and was stopped. No image was created.",
                "完成时间过长，已停止且没有生成图片。"
            )
        case .cancelled:
            ClipLocalization.text(
                "The capture was cancelled.",
                "已取消截图。"
            )
        }
    }
}
