import AppKit
import ClipCore

private final class TransientPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        sharingType = .none
    }
}

@MainActor
final class CaptureSuccessToastController: NSObject {
    private let panel: TransientPanel
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(
        labelWithString: ClipLocalization.text("Copied", "已复制")
    )
    private var hideTimer: Timer?
    private var transitionGeneration = 0

    override init() {
        panel = TransientPanel(
            contentRect: NSRect(x: 0, y: 0, width: 132, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    func show(message: String? = nil) {
        let message = message ?? ClipLocalization.text("Copied", "已复制")
        messageLabel.stringValue = message
        iconView.setAccessibilityLabel(message)
        let messageWidth = ceil(messageLabel.intrinsicContentSize.width)
        panel.setContentSize(NSSize(
            width: max(132, min(260, 14 + 18 + 8 + messageWidth + 14)),
            height: 44
        ))
        positionPanel()

        hideTimer?.invalidate()
        transitionGeneration &+= 1
        panel.contentView?.layer?.removeAllAnimations()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        transitionGeneration &+= 1
        let generation = transitionGeneration
        panel.contentView?.layer?.removeAllAnimations()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transitionGeneration == generation else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: ClipLocalization.text("Copied", "已复制")
        )
        iconView.contentTintColor = .systemGreen
        iconView.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        guard let contentView = panel.contentView else { return }
        contentView.addSubview(effect)
        effect.addSubview(iconView)
        effect.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            effect.topAnchor.constraint(equalTo: contentView.topAnchor),
            effect.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            messageLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            messageLabel.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14)
        ])
    }

    private func positionPanel() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - panel.frame.width - 16,
            y: visibleFrame.minY + 16
        ))
    }
}

@MainActor
final class CaptureProgressHUDController: NSObject {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?

    private let panel: TransientPanel
    private let finishButton = NSButton()
    private var transitionGeneration = 0
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    override init() {
        panel = TransientPanel(
            contentRect: NSRect(x: 0, y: 0, width: 92, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    func show(near selection: CGRect) {
        finishButton.title = ClipLocalization.text("Done", "完成")
        finishButton.setAccessibilityLabel(
            ClipLocalization.text("Finish scrolling capture", "完成滚动截图")
        )
        panel.setContentSize(NSSize(width: 92, height: 44))
        finishButton.isEnabled = true
        installKeyMonitors()
        positionPanel(near: selection)

        transitionGeneration &+= 1
        panel.contentView?.layer?.removeAllAnimations()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func showProcessing() {
        finishButton.title = ClipLocalization.text("Finishing…", "正在完成…")
        panel.setContentSize(NSSize(width: 124, height: 44))
        finishButton.isEnabled = false
    }

    func hide() {
        removeKeyMonitors()
        transitionGeneration &+= 1
        let generation = transitionGeneration
        panel.contentView?.layer?.removeAllAnimations()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transitionGeneration == generation else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        finishButton.translatesAutoresizingMaskIntoConstraints = false
        finishButton.title = ClipLocalization.text("Done", "完成")
        finishButton.bezelStyle = .recessed
        finishButton.font = .systemFont(ofSize: 13, weight: .semibold)
        finishButton.target = self
        finishButton.action = #selector(finish)
        finishButton.setAccessibilityLabel(
            ClipLocalization.text("Finish scrolling capture", "完成滚动截图")
        )

        guard let contentView = panel.contentView else { return }
        contentView.addSubview(effect)
        effect.addSubview(finishButton)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            effect.topAnchor.constraint(equalTo: contentView.topAnchor),
            effect.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            finishButton.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            finishButton.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            finishButton.topAnchor.constraint(equalTo: effect.topAnchor, constant: 6),
            finishButton.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6)
        ])
    }

    private func positionPanel(near selection: CGRect) {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: selection.midX, y: selection.midY)) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }

        let x = min(
            max(selection.maxX - panel.frame.width, visibleFrame.minX + 8),
            visibleFrame.maxX - panel.frame.width - 8
        )
        let above = selection.maxY + 8
        let below = selection.minY - panel.frame.height - 8
        let y = above + panel.frame.height <= visibleFrame.maxY
            ? above
            : max(below, visibleFrame.minY + 8)
        panel.setFrameOrigin(NSPoint(
            x: x,
            y: y
        ))
    }

    private func installKeyMonitors() {
        removeKeyMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.onCancel?()
            return nil
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.onCancel?() }
        }
    }

    private func removeKeyMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }

    @objc private func finish() {
        onFinish?()
    }
}
