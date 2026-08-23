import Foundation
import ClipCore

enum CaptureExperienceMode: String, CaseIterable, Sendable {
    case minimal
    case advanced
}

enum CaptureExperiencePreferences {
    static let modeKey = "cc.clip.mac.capture-experience"

    static var mode: CaptureExperienceMode {
        get { mode(in: .standard) }
        set { setMode(newValue, in: .standard) }
    }

    static func mode(in defaults: UserDefaults) -> CaptureExperienceMode {
        guard let stored = defaults.string(forKey: modeKey),
              let mode = CaptureExperienceMode(rawValue: stored) else {
            return .minimal
        }
        return mode
    }

    static func setMode(
        _ mode: CaptureExperienceMode,
        in defaults: UserDefaults
    ) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    static func usesEditor(
        for captureMode: CaptureMode,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        switch captureMode {
        case .region, .scrolling:
            mode(in: defaults) == .advanced
        }
    }
}
