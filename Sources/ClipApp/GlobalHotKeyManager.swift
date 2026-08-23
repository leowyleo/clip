import AppKit
import Carbon.HIToolbox

enum ClipHotKeyAction: UInt32 {
    case region = 1
    case scrolling = 2
}

struct HotKeyDescriptor: Sendable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.displayName(for: keyCode)
        return result
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// AppKit uses a textual key equivalent to render its native shortcut column.
    /// Keep this intentionally smaller than Carbon's key-code space; unsupported keys
    /// still work globally and use the textual fallback in the status menu.
    var appKitKeyEquivalent: String? {
        switch Int(keyCode) {
        case kVK_ANSI_A: "a"
        case kVK_ANSI_B: "b"
        case kVK_ANSI_C: "c"
        case kVK_ANSI_D: "d"
        case kVK_ANSI_E: "e"
        case kVK_ANSI_F: "f"
        case kVK_ANSI_G: "g"
        case kVK_ANSI_H: "h"
        case kVK_ANSI_I: "i"
        case kVK_ANSI_J: "j"
        case kVK_ANSI_K: "k"
        case kVK_ANSI_L: "l"
        case kVK_ANSI_M: "m"
        case kVK_ANSI_N: "n"
        case kVK_ANSI_O: "o"
        case kVK_ANSI_P: "p"
        case kVK_ANSI_Q: "q"
        case kVK_ANSI_R: "r"
        case kVK_ANSI_S: "s"
        case kVK_ANSI_T: "t"
        case kVK_ANSI_U: "u"
        case kVK_ANSI_V: "v"
        case kVK_ANSI_W: "w"
        case kVK_ANSI_X: "x"
        case kVK_ANSI_Y: "y"
        case kVK_ANSI_Z: "z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_Space: " "
        default: nil
        }
    }

    private static func displayName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_Space: "Space"
        default: "Key \(keyCode)"
        }
    }

    static func from(event: NSEvent) -> HotKeyDescriptor? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers != 0 else { return nil }
        return HotKeyDescriptor(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
    }
}

enum HotKeyPreferences {
    private static let regionKeyCodeKey = "clip.hotKey.region.keyCode"
    private static let regionModifiersKey = "clip.hotKey.region.modifiers"
    private static let scrollingKeyCodeKey = "clip.hotKey.scrolling.keyCode"
    private static let scrollingModifiersKey = "clip.hotKey.scrolling.modifiers"

    static var region: HotKeyDescriptor {
        descriptor(
            keyCodeKey: regionKeyCodeKey,
            modifiersKey: regionModifiersKey,
            defaultKeyCode: UInt32(kVK_ANSI_4)
        )
    }

    static var scrolling: HotKeyDescriptor {
        descriptor(
            keyCodeKey: scrollingKeyCodeKey,
            modifiersKey: scrollingModifiersKey,
            defaultKeyCode: UInt32(kVK_ANSI_5)
        )
    }

    static func setRegion(_ descriptor: HotKeyDescriptor) {
        set(
            descriptor,
            keyCodeKey: regionKeyCodeKey,
            modifiersKey: regionModifiersKey
        )
    }

    static func setScrolling(_ descriptor: HotKeyDescriptor) {
        set(
            descriptor,
            keyCodeKey: scrollingKeyCodeKey,
            modifiersKey: scrollingModifiersKey
        )
    }

    static func canAssign(_ descriptor: HotKeyDescriptor, to action: ClipHotKeyAction) -> Bool {
        switch action {
        case .region:
            descriptor != scrolling
        case .scrolling:
            descriptor != region
        }
    }

    private static func set(
        _ descriptor: HotKeyDescriptor,
        keyCodeKey: String,
        modifiersKey: String
    ) {
        let defaults = UserDefaults.standard
        defaults.set(Int(descriptor.keyCode), forKey: keyCodeKey)
        defaults.set(Int(descriptor.carbonModifiers), forKey: modifiersKey)
        NotificationCenter.default.post(name: .clipHotKeysChanged, object: nil)
    }

    private static func descriptor(
        keyCodeKey: String,
        modifiersKey: String,
        defaultKeyCode: UInt32
    ) -> HotKeyDescriptor {
        let defaults = UserDefaults.standard
        // Avoid macOS's reserved screenshot shortcuts while keeping both actions
        // reachable with one hand: Control-Option-4 and Control-Option-5.
        let defaultModifiers = UInt32(controlKey | optionKey)

        let keyCode: UInt32
        if defaults.object(forKey: keyCodeKey) == nil {
            keyCode = defaultKeyCode
        } else {
            keyCode = UInt32(clamping: defaults.integer(forKey: keyCodeKey))
        }

        let modifiers: UInt32
        if defaults.object(forKey: modifiersKey) == nil {
            modifiers = defaultModifiers
        } else {
            modifiers = UInt32(clamping: defaults.integer(forKey: modifiersKey))
        }

        return HotKeyDescriptor(keyCode: keyCode, carbonModifiers: modifiers)
    }
}

extension Notification.Name {
    static let clipHotKeysChanged = Notification.Name("cc.clip.mac.hotKeysChanged")
}

enum GlobalHotKeyError: Error {
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(action: ClipHotKeyAction, status: OSStatus)
}

@MainActor
final class GlobalHotKeyManager {
    var onRegionCapture: (() -> Void)?
    var onScrollingCapture: (() -> Void)?

    private var eventHandlerReference: EventHandlerRef?
    private var hotKeyReferences: [EventHotKeyRef] = []

    /// Checks a newly recorded shortcut before replacing the working registrations.
    /// The current action's old shortcut remains registered while this probe runs.
    static func isAvailable(_ descriptor: HotKeyDescriptor) -> Bool {
        let identifier = EventHotKeyID(
            signature: OSType(0x434C_5052), // "CLPR"
            id: 1
        )
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            descriptor.keyCode,
            descriptor.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        UnregisterEventHotKey(reference)
        return true
    }

    func registerConfiguredHotKeys() throws {
        unregisterAll()
        try installEventHandlerIfNeeded()
        try register(HotKeyPreferences.region, action: .region)

        do {
            try register(HotKeyPreferences.scrolling, action: .scrolling)
        } catch {
            unregisterAll()
            throw error
        }
    }

    func unregisterAll() {
        hotKeyReferences.forEach { UnregisterEventHotKey($0) }
        hotKeyReferences.removeAll()

        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandlerReference == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyEventHandler,
            1,
            &eventType,
            userData,
            &handler
        )

        guard status == noErr, let handler else {
            throw GlobalHotKeyError.eventHandlerInstallationFailed(status)
        }
        eventHandlerReference = handler
    }

    private func register(
        _ descriptor: HotKeyDescriptor,
        action: ClipHotKeyAction
    ) throws {
        let identifier = EventHotKeyID(
            signature: OSType(0x434C_4950), // "CLIP"
            id: action.rawValue
        )
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            descriptor.keyCode,
            descriptor.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            throw GlobalHotKeyError.registrationFailed(action: action, status: status)
        }
        hotKeyReferences.append(reference)
    }

    private func dispatch(_ actionID: UInt32) {
        guard let action = ClipHotKeyAction(rawValue: actionID) else { return }
        switch action {
        case .region:
            onRegionCapture?()
        case .scrolling:
            onScrollingCapture?()
        }
    }

    private nonisolated static let hotKeyEventHandler: EventHandlerUPP = {
        _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr else { return status }

        // The Carbon handler owns only an unretained pointer. Retain synchronously before
        // hopping to MainActor so a settings-triggered hot-key reload cannot deallocate the
        // manager while this event is queued.
        let retainedManagerAddress = UInt(
            bitPattern: Unmanaged<GlobalHotKeyManager>
                .fromOpaque(userData)
                .retain()
                .toOpaque()
        )
        let actionID = identifier.id
        Task { @MainActor in
            guard let pointer = UnsafeRawPointer(bitPattern: retainedManagerAddress) else { return }
            let manager = Unmanaged<GlobalHotKeyManager>
                .fromOpaque(pointer)
                .takeRetainedValue()
            manager.dispatch(actionID)
        }
        return noErr
    }
}
