import AppKit
import ClipCore

@MainActor
final class ClipAppDelegate: NSObject, NSApplicationDelegate {
    private enum StartupAction {
        case captureRegion
        case captureScrolling
        case showSettings
    }

    typealias CaptureRequestHandler = (
        _ mode: CaptureMode,
        _ region: CaptureRegion,
        _ activatePassiveFrame: @escaping () -> Void,
        _ dismissSelection: @escaping () -> Void
    ) -> Void

    /// The capture targets can install their implementation here without coupling the app shell
    /// to a concrete capture engine.
    var onCaptureRequested: CaptureRequestHandler?
    var onCaptureCancelled: (() -> Void)?
    var onCaptureFinished: (() -> Void)?

    private let permissionGuide: PermissionGuiding
    private let selectionOverlay = SelectionOverlayController()
    private let annotationEditor = AnnotationEditorController()
    private let successController = CaptureSuccessToastController()
    private let progressController = CaptureProgressHUDController()
    private let settingsController: SettingsWindowController

    private var statusItem: NSStatusItem?
    private var hotKeyManager: GlobalHotKeyManager?
    private var hotKeyChangeObserver: NSObjectProtocol?
    private var pendingMode: CaptureMode?

    override init() {
        let guide = SystemPermissionGuide()
        permissionGuide = guide
        settingsController = SettingsWindowController(permissionGuide: guide)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureHotKeys()
        installCaptureBridge()
        hotKeyChangeObserver = NotificationCenter.default.addObserver(
            forName: .clipHotKeysChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadHotKeys()
            }
        }
        performStartupActionIfPresent()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager?.unregisterAll()
        selectionOverlay.cancel()
        annotationEditor.cancel()
        if let hotKeyChangeObserver {
            NotificationCenter.default.removeObserver(hotKeyChangeObserver)
        }
    }

    @objc private func captureRegionFromMenu() {
        beginSelection(for: .region)
    }

    @objc private func captureScrollingFromMenu() {
        beginSelection(for: .scrolling)
    }

    @objc private func showSettings() {
        settingsController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsController.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Capture coordinator bridge

    func showScrollingCaptureControl(near region: CGRect) {
        progressController.show(near: region)
    }

    func showCaptureProcessing() {
        progressController.showProcessing()
    }

    func hideCaptureProgress() {
        progressController.hide()
    }

    func showCaptureCompletion() {
        progressController.hide()
        successController.show()
    }

    func showOCRCompletion() {
        progressController.hide()
        successController.show(
            message: ClipLocalization.text("OCR text copied", "文字 OCR 复制成功")
        )
    }

    func editCapture(
        _ image: CGImage,
        over region: CGRect,
        replacingSelection dismissSelection: (() -> Void)? = nil
    ) async throws -> AnnotationEditorResult {
        let editor = annotationEditor
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                editor.present(
                    image: image,
                    over: region,
                    allowsExpansion: false,
                    recapture: nil,
                    selectionOverlayController: nil,
                    onComplete: { editedImage in
                        continuation.resume(returning: .image(editedImage))
                    },
                    onTextCopied: {
                        continuation.resume(returning: .ocrTextCopied)
                    },
                    onCancel: {
                        continuation.resume(throwing: CancellationError())
                    }
                )
                // Scrolling capture has no secondary region adjustment.
                dismissSelection?()
            }
        } onCancel: {
            Task { @MainActor in
                editor.cancel()
            }
        }
    }

    func editLiveCapture(
        over region: CGRect,
        capture: @escaping (CGRect) async throws -> CGImage
    ) async throws -> AnnotationEditorResult {
        let editor = annotationEditor
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                editor.presentLive(
                    over: region,
                    capture: capture,
                    selectionOverlayController: selectionOverlay,
                    onComplete: { editedImage in
                        continuation.resume(returning: .image(editedImage))
                    },
                    onTextCopied: {
                        continuation.resume(returning: .ocrTextCopied)
                    },
                    onCancel: {
                        continuation.resume(throwing: CancellationError())
                    }
                )
            }
        } onCancel: {
            Task { @MainActor in
                editor.cancel()
            }
        }
    }

    func presentCaptureError(
        _ error: Error,
        retryMode: CaptureMode? = nil
    ) {
        progressController.hide()
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = ClipLocalization.text("Capture Not Completed", "截图未完成")
        alert.informativeText = message
        if retryMode != nil {
            alert.addButton(withTitle: ClipLocalization.text("Try Again", "重试"))
        }
        alert.addButton(withTitle: ClipLocalization.text("OK", "好"))
        let response = runAlertRestoringFocus(alert)
        guard response == .alertFirstButtonReturn, let retryMode else { return }
        DispatchQueue.main.async { [weak self] in
            self?.beginSelection(for: retryMode)
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 40)
        guard let button = item.button else { return }

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        button.image = NSImage(
            systemSymbolName: "viewfinder",
            accessibilityDescription: ClipLocalization.text("Clip Capture", "Clip 截图")
        )?.withSymbolConfiguration(symbolConfiguration)
        button.imagePosition = .imageOnly
        button.toolTip = "Clip"
        button.setAccessibilityLabel(ClipLocalization.text("Clip capture menu", "Clip 截图菜单"))
        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let region = NSMenuItem(
            title: ClipLocalization.text("Region Capture", "区域截图"),
            action: #selector(captureRegionFromMenu),
            keyEquivalent: HotKeyPreferences.region.appKitKeyEquivalent ?? ""
        )
        region.target = self
        region.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        region.applyShortcutDisplay(HotKeyPreferences.region)
        menu.addItem(region)

        let scrolling = NSMenuItem(
            title: ClipLocalization.text("Scrolling Capture", "滚动截图"),
            action: #selector(captureScrollingFromMenu),
            keyEquivalent: HotKeyPreferences.scrolling.appKitKeyEquivalent ?? ""
        )
        scrolling.target = self
        scrolling.image = NSImage(systemSymbolName: "rectangle.and.hand.point.up.left", accessibilityDescription: nil)
        scrolling.applyShortcutDisplay(HotKeyPreferences.scrolling)
        menu.addItem(scrolling)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: ClipLocalization.text("Settings…", "设置…"),
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settings.target = self
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: ClipLocalization.text("Quit Clip", "退出 Clip"),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)
        return menu
    }

    private func configureHotKeys() {
        let manager = GlobalHotKeyManager()
        manager.onRegionCapture = { [weak self] in
            self?.beginSelection(for: .region)
        }
        manager.onScrollingCapture = { [weak self] in
            self?.beginSelection(for: .scrolling)
        }

        do {
            try manager.registerConfiguredHotKeys()
            hotKeyManager = manager
        } catch {
            presentMessage(
                title: ClipLocalization.text(
                    "Shortcuts Could Not Be Registered",
                    "无法注册快捷键"
                ),
                message: ClipLocalization.text(
                    "Another app may be using a shortcut. You can still start a capture from the menu bar.",
                    "快捷键可能正被其他应用使用。仍可从菜单栏启动截图。"
                )
            )
        }
    }

    private func reloadHotKeys() {
        hotKeyManager?.unregisterAll()
        configureHotKeys()
        statusItem?.menu = makeMenu()
    }

    private func performStartupActionIfPresent() {
        let arguments = ProcessInfo.processInfo.arguments
        let action: StartupAction?
        if arguments.contains("--capture-region") {
            action = .captureRegion
        } else if arguments.contains("--capture-scrolling") {
            action = .captureScrolling
        } else if arguments.contains("--settings") {
            action = .showSettings
        } else {
            action = nil
        }

        guard let action else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            switch action {
            case .captureRegion:
                self.beginSelection(for: .region)
            case .captureScrolling:
                self.beginSelection(for: .scrolling)
            case .showSettings:
                self.showSettings()
            }
        }
    }

    private func beginSelection(for mode: CaptureMode) {
        guard !selectionOverlay.isPresenting, !annotationEditor.isPresenting else {
            NSSound.beep()
            return
        }
        guard permissionGuide.screenRecordingStatus == .granted else {
            requestScreenRecordingPermission()
            return
        }

        pendingMode = mode
        selectionOverlay.present(
            keepsDimWhilePassive: mode == .region,
            onSelection: { [weak self] rect, activatePassiveFrame, dismiss in
                self?.completeSelection(
                    rect,
                    activatePassiveFrame: activatePassiveFrame,
                    dismissSelection: dismiss
                )
            },
            onCancel: { [weak self] in
                self?.pendingMode = nil
                self?.onCaptureCancelled?()
            }
        )
    }

    private func completeSelection(
        _ rect: CGRect,
        activatePassiveFrame: @escaping () -> Void,
        dismissSelection: @escaping () -> Void
    ) {
        guard let mode = pendingMode else {
            dismissSelection()
            return
        }
        pendingMode = nil

        let region = CaptureRegion(rect: rect)
        guard region.isUsable else {
            dismissSelection()
            presentMessage(
                title: ClipLocalization.text("Selection Too Small", "选区太小"),
                message: ClipLocalization.text(
                    "Select a larger capture area.",
                    "请框选更大的截图区域。"
                )
            )
            return
        }

        guard let handler = onCaptureRequested else {
            dismissSelection()
            presentMessage(
                title: ClipLocalization.text("Capture Unavailable", "截图不可用"),
                message: ClipLocalization.text(
                    "Restart Clip and try again.",
                    "请重新启动 Clip 后再试。"
                )
            )
            return
        }

        handler(mode, region, activatePassiveFrame, dismissSelection)
    }

    private func installCaptureBridge() {
        progressController.onCancel = { [weak self] in
            self?.progressController.hide()
            self?.onCaptureCancelled?()
        }
        progressController.onFinish = { [weak self] in
            self?.onCaptureFinished?()
        }
    }

    private func requestScreenRecordingPermission() {
        let granted = permissionGuide.requestScreenRecordingAccess()
        if granted {
            presentMessage(
                title: ClipLocalization.text("Permission Enabled", "权限已开启"),
                message: ClipLocalization.text(
                    "Start the capture again.",
                    "请再次启动截图。"
                )
            )
        } else {
            presentPermissionAlert(
                title: ClipLocalization.text(
                    "Screen Capture Permission Required",
                    "需要屏幕读取权限"
                ),
                message: ClipLocalization.text(
                    "Allow Clip in System Settings under Screen & System Audio Recording. Clip reads only the selected pixels, processes everything locally, and never saves video.",
                    "请在系统设置的“屏幕与系统音频录制”中允许 Clip。Clip 只读取选区像素，所有处理均在本机完成，不保存视频。"
                ),
                permission: .screenRecording
            )
        }
    }

    private func presentPermissionAlert(
        title: String,
        message: String,
        permission: ClipPermission
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(
            withTitle: ClipLocalization.text("Open System Settings", "打开系统设置")
        )
        alert.addButton(withTitle: ClipLocalization.text("Later", "稍后"))
        let response = runAlertRestoringFocus(alert, restoreFocus: false)

        if response == .alertFirstButtonReturn {
            lastExternalApplication = nil
            permissionGuide.openSystemSettings(for: permission)
        } else {
            restoreLastExternalApplication()
        }
    }

    private func presentMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: ClipLocalization.text("OK", "好"))
        _ = runAlertRestoringFocus(alert)
    }

    private weak var lastExternalApplication: NSRunningApplication?

    @discardableResult
    private func runAlertRestoringFocus(
        _ alert: NSAlert,
        restoreFocus: Bool = true
    ) -> NSApplication.ModalResponse {
        let activeApplication = NSWorkspace.shared.frontmostApplication
        if activeApplication?.processIdentifier != NSRunningApplication.current.processIdentifier {
            lastExternalApplication = activeApplication
        } else {
            lastExternalApplication = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if restoreFocus {
            restoreLastExternalApplication()
        }
        return response
    }

    private func restoreLastExternalApplication() {
        lastExternalApplication?.activate()
        lastExternalApplication = nil
    }
}

private extension NSMenuItem {
    func applyShortcutDisplay(_ descriptor: HotKeyDescriptor) {
        if descriptor.appKitKeyEquivalent != nil {
            keyEquivalentModifierMask = descriptor.cocoaModifiers
        } else {
            keyEquivalentDescription = descriptor.displayString
        }
    }

    /// AppKit only exposes a key-equivalent string generated from `keyEquivalent`.
    /// We keep a visual shortcut column without installing a second local shortcut.
    var keyEquivalentDescription: String? {
        get { representedObject as? String }
        set {
            representedObject = newValue
            guard let newValue else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 220)]
            paragraph.defaultTabInterval = 220
            attributedTitle = NSAttributedString(
                string: "\(title)\t\(newValue)",
                attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .paragraphStyle: paragraph,
                    .foregroundColor: NSColor.labelColor
                ]
            )
        }
    }
}
