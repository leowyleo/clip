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
            "请允许 Clip 读取所选屏幕内容。"
        case .invalidSelection:
            "请选择更大的截图区域。"
        case .captureFailed:
            "这次截图没有完成，未生成图片。"
        case .protectedContent:
            "此内容受系统保护，无法截取。"
        case .noScrollableContent:
            "没有检测到更多内容。"
        case .unstableContent:
            "画面持续变化，这次没有生成图片。"
        case .stitchConfidenceTooLow:
            "画面没有保持连续，这次没有生成图片。"
        case .outputTooLarge:
            "已达到安全长度，这次没有生成图片。"
        case .processingTimedOut:
            "完成时间过长，已停止且没有生成图片。"
        case .cancelled:
            "已取消截图。"
        }
    }
}
