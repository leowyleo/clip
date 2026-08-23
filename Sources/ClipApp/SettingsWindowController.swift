import AppKit
import ClipCore

@MainActor
private final class ShortcutRecorderButton: NSButton {
    var descriptor: HotKeyDescriptor {
        didSet { title = descriptor.displayString }
    }
    var onChange: ((HotKeyDescriptor) -> Bool)?

    private var isRecording = false

    init(descriptor: HotKeyDescriptor) {
        self.descriptor = descriptor
        super.init(frame: .zero)
        title = descriptor.displayString
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel("设置快捷键")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            finishRecording()
            return
        }
        guard let proposed = HotKeyDescriptor.from(event: event) else {
            NSSound.beep()
            title = "请包含修饰键"
            return
        }
        guard onChange?(proposed) != false else {
            NSSound.beep()
            title = "快捷键已被使用"
            return
        }
        descriptor = proposed
        finishRecording()
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { finishRecording() }
        return super.resignFirstResponder()
    }

    @objc private func beginRecording() {
        isRecording = true
        title = "请按快捷键…"
        window?.makeFirstResponder(self)
    }

    private func finishRecording() {
        isRecording = false
        title = descriptor.displayString
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let permissionGuide: PermissionGuiding
    private let screenStatus = NSTextField(labelWithString: "")
    private var experienceControl: NSSegmentedControl?
    private var regionRecorder: ShortcutRecorderButton?
    private var scrollingRecorder: ShortcutRecorderButton?
    private weak var previouslyActiveApplication: NSRunningApplication?

    init(permissionGuide: PermissionGuiding) {
        self.permissionGuide = permissionGuide
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 354),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clip 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible != true {
            let activeApplication = NSWorkspace.shared.frontmostApplication
            if activeApplication?.processIdentifier != NSRunningApplication.current.processIdentifier {
                previouslyActiveApplication = activeApplication
            }
        }
        refreshPermissionStatus()
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        previouslyActiveApplication?.activate()
        previouslyActiveApplication = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // System Settings may update TCC while this window remains open in the
        // background. Refresh as soon as the user returns to Clip.
        refreshPermissionStatus()
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Clip")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "框住，就能粘贴。")
        subtitle.textColor = .secondaryLabelColor

        let experienceHeader = sectionLabel("截图体验")
        let experienceRow = captureExperienceRow()
        let experienceHint = NSTextField(
            wrappingLabelWithString: "高级模式用于区域截图；滚动截图仍直接复制。"
        )
        experienceHint.font = .systemFont(ofSize: 11)
        experienceHint.textColor = .tertiaryLabelColor

        let shortcutHeader = sectionLabel("快捷键")
        let regionRow = shortcutRow(label: "区域截图", mode: .region)
        let scrollRow = shortcutRow(label: "滚动截图", mode: .scrolling)

        let permissionHeader = sectionLabel("权限")
        let screenRow = permissionRow(
            label: "屏幕读取",
            status: screenStatus,
            action: #selector(openScreenRecordingSettings)
        )
        let stack = NSStackView(views: [
            title,
            subtitle,
            experienceHeader,
            experienceRow,
            experienceHint,
            shortcutHeader,
            regionRow,
            scrollRow,
            permissionHeader,
            screenRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(2, after: title)
        stack.setCustomSpacing(18, after: subtitle)
        stack.setCustomSpacing(12, after: experienceHeader)
        stack.setCustomSpacing(4, after: experienceRow)
        stack.setCustomSpacing(18, after: experienceHint)
        stack.setCustomSpacing(12, after: shortcutHeader)
        stack.setCustomSpacing(18, after: scrollRow)
        stack.setCustomSpacing(12, after: permissionHeader)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            experienceRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            experienceHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            regionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            screenRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        refreshPermissionStatus()
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func shortcutRow(label: String, mode: CaptureMode) -> NSView {
        let name = NSTextField(labelWithString: label)
        let descriptor = mode == .region ? HotKeyPreferences.region : HotKeyPreferences.scrolling
        let recorder = ShortcutRecorderButton(descriptor: descriptor)
        recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 32).isActive = true
        recorder.onChange = { proposed in
            let current = mode == .region ? HotKeyPreferences.region : HotKeyPreferences.scrolling
            let action: ClipHotKeyAction = mode == .region ? .region : .scrolling
            guard HotKeyPreferences.canAssign(proposed, to: action) else { return false }
            guard proposed == current || GlobalHotKeyManager.isAvailable(proposed) else {
                return false
            }
            if mode == .region {
                HotKeyPreferences.setRegion(proposed)
            } else {
                HotKeyPreferences.setScrolling(proposed)
            }
            return true
        }
        if mode == .region {
            regionRecorder = recorder
        } else {
            scrollingRecorder = recorder
        }

        let spacer = NSView()
        let row = NSStackView(views: [name, spacer, recorder])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: 36).isActive = true
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func captureExperienceRow() -> NSView {
        let name = NSTextField(labelWithString: "区域截图")
        let spacer = NSView()
        let control = NSSegmentedControl(
            labels: ["极简", "高级"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(captureExperienceChanged(_:))
        )
        control.controlSize = .large
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: 180).isActive = true
        control.heightAnchor.constraint(equalToConstant: 32).isActive = true
        control.setAccessibilityLabel("区域截图模式")
        experienceControl = control

        let row = NSStackView(views: [name, spacer, control])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: 36).isActive = true
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func permissionRow(
        label: String,
        status: NSTextField,
        action: Selector
    ) -> NSView {
        let name = NSTextField(labelWithString: label)
        status.textColor = .secondaryLabelColor

        let spacer = NSView()
        let button = NSButton(title: "设置…", target: self, action: action)
        button.bezelStyle = .rounded
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [name, spacer, status, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.heightAnchor.constraint(equalToConstant: 36).isActive = true
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func refreshPermissionStatus() {
        experienceControl?.selectedSegment = CaptureExperiencePreferences.mode == .advanced
            ? 1
            : 0
        regionRecorder?.descriptor = HotKeyPreferences.region
        scrollingRecorder?.descriptor = HotKeyPreferences.scrolling
        screenStatus.stringValue = permissionGuide.screenRecordingStatus == .granted
            ? "已允许"
            : "未允许"
    }

    @objc private func captureExperienceChanged(_ sender: NSSegmentedControl) {
        CaptureExperiencePreferences.mode = sender.selectedSegment == 1
            ? .advanced
            : .minimal
    }

    @objc private func openScreenRecordingSettings() {
        permissionGuide.openSystemSettings(for: .screenRecording)
    }

}
