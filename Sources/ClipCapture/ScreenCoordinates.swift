import CoreGraphics

/// Converts AppKit's global screen coordinates (origin at the bottom-left of the
/// main display) to Quartz/ScreenCaptureKit coordinates (origin at the top-left).
public struct ScreenCoordinateConverter: Sendable {
    private enum MainDisplayReference: Sendable {
        case current
        case fixed(CGFloat)
    }

    private var mainDisplayReference: MainDisplayReference

    /// The live main-display height for a default converter. Assigning a value
    /// switches the converter to a fixed reference, which is useful for tests.
    public var mainDisplayHeight: CGFloat {
        get {
            switch mainDisplayReference {
            case .current:
                CGDisplayBounds(CGMainDisplayID()).height
            case let .fixed(height):
                height
            }
        }
        set {
            mainDisplayReference = .fixed(newValue)
        }
    }

    public init(mainDisplayHeight: CGFloat) {
        mainDisplayReference = .fixed(mainDisplayHeight)
    }

    public init() {
        mainDisplayReference = .current
    }

    public func quartzRect(fromAppKit rect: CGRect) -> CGRect {
        let rect = rect.standardized
        return CGRect(
            x: rect.minX,
            y: mainDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
