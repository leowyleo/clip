import AppKit

/// Presents one transparent window per display and reports a rectangle in the global AppKit
/// screen coordinate space. The rectangle can cross display boundaries.
@MainActor
final class SelectionOverlayController: NSObject, SelectionOverlayViewDelegate {
    typealias SelectionHandler = (
        _ rect: CGRect,
        _ activatePassiveFrame: @escaping () -> Void,
        _ dismiss: @escaping () -> Void
    ) -> Void

    private(set) var isPresenting = false

    private var windows: [SelectionOverlayWindow] = []
    private var eventMonitor: Any?
    private var startingPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var isCompletingSelection = false
    private var presentationID: UUID?
    private var cursorIsPushed = false
    private var onSelection: SelectionHandler?
    private var onCancel: (() -> Void)?
    private weak var previouslyActiveApplication: NSRunningApplication?

    func present(
        onSelection: @escaping SelectionHandler,
        onCancel: @escaping () -> Void
    ) {
        guard !isPresenting else { return }
        guard !NSScreen.screens.isEmpty else {
            onCancel()
            return
        }

        isPresenting = true
        presentationID = UUID()
        self.onSelection = onSelection
        self.onCancel = onCancel
        previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
        NSCursor.crosshair.push()
        cursorIsPushed = true

        windows = NSScreen.screens.map { screen in
            let window = SelectionOverlayWindow(screen: screen)
            let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.delegate = self
            window.contentView = view
            window.orderFrontRegardless()
            return window
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel()
            return nil
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
    }

    func cancel() {
        guard isPresenting, let presentationID else { return }
        let handler = onCancel
        tearDown(presentationID: presentationID)
        handler?()
    }

    fileprivate func selectionView(_ view: SelectionOverlayView, beganAt screenPoint: CGPoint) {
        guard !isCompletingSelection else { return }
        startingPoint = screenPoint
        currentPoint = screenPoint
        updateViews()
    }

    fileprivate func selectionView(_ view: SelectionOverlayView, movedTo screenPoint: CGPoint) {
        guard !isCompletingSelection, startingPoint != nil else { return }
        currentPoint = screenPoint
        updateViews()
    }

    fileprivate func selectionView(_ view: SelectionOverlayView, endedAt screenPoint: CGPoint) {
        guard !isCompletingSelection, let startingPoint else { return }
        currentPoint = screenPoint
        let rect = SelectionGeometry.rectangle(from: startingPoint, to: screenPoint)

        guard rect.width >= 8, rect.height >= 8 else {
            self.startingPoint = nil
            currentPoint = nil
            NSSound.beep()
            updateViews()
            return
        }

        isCompletingSelection = true
        updateViews()
        guard let presentationID else { return }
        onSelection?(
            rect,
            { [weak self] in
                self?.activatePassiveFrame(presentationID: presentationID)
            },
            { [weak self] in
                self?.tearDown(presentationID: presentationID)
            }
        )
    }

    private func updateViews() {
        let selection: CGRect?
        if let startingPoint, let currentPoint {
            selection = SelectionGeometry.rectangle(from: startingPoint, to: currentPoint)
        } else {
            selection = nil
        }

        for window in windows {
            guard let view = window.contentView as? SelectionOverlayView else { continue }
            view.globalSelection = selection
            view.needsDisplay = true
        }
    }

    private func activatePassiveFrame(presentationID: UUID) {
        guard self.presentationID == presentationID, isPresenting else { return }
        removeEventMonitor()

        for window in windows {
            window.ignoresMouseEvents = true
            guard let view = window.contentView as? SelectionOverlayView else { continue }
            view.displayMode = .passiveFrame
            view.needsDisplay = true
        }

        discardSelectionCursor()
        restorePreviousApplication()
    }

    private func tearDown(presentationID: UUID) {
        guard self.presentationID == presentationID, isPresenting else { return }
        removeEventMonitor()

        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        startingPoint = nil
        currentPoint = nil
        isCompletingSelection = false
        self.presentationID = nil
        onSelection = nil
        onCancel = nil
        isPresenting = false
        discardSelectionCursor()
        restorePreviousApplication()
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func discardSelectionCursor() {
        guard cursorIsPushed else { return }
        NSCursor.pop()
        cursorIsPushed = false
    }

    private func restorePreviousApplication() {
        previouslyActiveApplication?.activate()
        previouslyActiveApplication = nil
    }

}

enum SelectionGeometry {
    static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        ).standardized
    }
}

@MainActor
fileprivate protocol SelectionOverlayViewDelegate: AnyObject {
    func selectionView(_ view: SelectionOverlayView, beganAt screenPoint: CGPoint)
    func selectionView(_ view: SelectionOverlayView, movedTo screenPoint: CGPoint)
    func selectionView(_ view: SelectionOverlayView, endedAt screenPoint: CGPoint)
}

fileprivate final class SelectionOverlayWindow: NSWindow {
    convenience init(screen: NSScreen) {
        self.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .none
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
}

fileprivate enum SelectionOverlayDisplayMode {
    case selecting
    case passiveFrame
}

@MainActor
fileprivate final class SelectionOverlayView: NSView {
    weak var delegate: SelectionOverlayViewDelegate?
    var globalSelection: CGRect?
    var displayMode: SelectionOverlayDisplayMode = .selecting

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        delegate?.selectionView(self, beganAt: globalPoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        delegate?.selectionView(self, movedTo: globalPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        delegate?.selectionView(self, endedAt: globalPoint(for: event))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setBlendMode(.copy)
            context.setFillColor(NSColor.clear.cgColor)
            context.fill(bounds)
            context.restoreGState()
        }

        if displayMode == .selecting {
            NSColor.black.withAlphaComponent(0.34).setFill()
            bounds.fill()
        }

        guard let globalSelection, let window else { return }
        let windowSelection = window.convertFromScreen(globalSelection)
        let localSelection = convert(windowSelection, from: nil)
        guard localSelection.intersects(bounds) else { return }

        if displayMode == .selecting {
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext.current?.cgContext {
                context.setBlendMode(.copy)
                context.setFillColor(NSColor.clear.cgColor)
                context.fill(localSelection)
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        let aligned = localSelection.insetBy(dx: 0.5, dy: 0.5)
        let border = NSBezierPath(rect: aligned)
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.96).setStroke()
        border.stroke()

        if displayMode == .selecting {
            drawSizeLabel(for: globalSelection, in: localSelection, window: window)
        }
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func drawSizeLabel(for globalRect: CGRect, in localRect: CGRect, window: NSWindow) {
        guard localRect.intersects(bounds), localRect.width > 64 else { return }
        let scale = window.screen?.backingScaleFactor ?? 1
        let text = "\(Int(globalRect.width * scale)) × \(Int(globalRect.height * scale))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let badgeSize = NSSize(width: textSize.width + 14, height: 22)

        var origin = NSPoint(
            x: localRect.minX,
            y: localRect.minY - badgeSize.height - 6
        )
        if origin.y < bounds.minY + 6 {
            origin.y = min(localRect.maxY + 6, bounds.maxY - badgeSize.height - 6)
        }
        origin.x = min(max(origin.x, bounds.minX + 6), bounds.maxX - badgeSize.width - 6)

        let badgeRect = NSRect(origin: origin, size: badgeSize)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6).fill()
        text.draw(
            at: NSPoint(
                x: badgeRect.minX + 7,
                y: badgeRect.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }
}
