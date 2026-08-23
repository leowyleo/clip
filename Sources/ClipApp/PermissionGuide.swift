import AppKit
import CoreGraphics

enum ClipPermission {
    case screenRecording
}

enum ClipPermissionStatus: Equatable {
    case granted
    case deniedOrNotDetermined
}

@MainActor
protocol PermissionGuiding: AnyObject {
    var screenRecordingStatus: ClipPermissionStatus { get }

    @discardableResult
    func requestScreenRecordingAccess() -> Bool
    func openSystemSettings(for permission: ClipPermission)
}

@MainActor
final class SystemPermissionGuide: PermissionGuiding {
    var screenRecordingStatus: ClipPermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .deniedOrNotDetermined
    }

    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func openSystemSettings(for permission: ClipPermission) {
        switch permission {
        case .screenRecording:
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ) else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
