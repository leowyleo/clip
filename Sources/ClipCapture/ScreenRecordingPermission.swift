import CoreGraphics

/// The screen-recording authorization boundary used by capture workflows.
/// Checking never presents UI; callers decide when it is appropriate to request access.
public protocol ScreenRecordingPermissionProviding: Sendable {
    func isAuthorized() -> Bool
    @discardableResult
    func requestAuthorization() -> Bool
}

public struct SystemScreenRecordingPermission: ScreenRecordingPermissionProviding {
    public init() {}

    public func isAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public func requestAuthorization() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
