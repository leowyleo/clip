import AppKit
import ClipCapture

enum SelectionOverlayChromeStyle {
    static let lineWidth: CGFloat = 1
    static let lineDashPattern: [NSNumber] = [3, 2]
    static let darkStrokeOpacity: CGFloat = 0.093
    static let lightStrokeOpacity: CGFloat = 0.137
    static let handleDiameter: CGFloat = 8

    static func referenceGray(over background: CGFloat) -> CGFloat {
        let darkened = background * (1 - darkStrokeOpacity)
        return lightStrokeOpacity + darkened * (1 - lightStrokeOpacity)
    }
}

enum AnnotationOverlayWindowLevel {
    static let selection = NSWindow.Level.screenSaver
    static let toolbar = NSWindow.Level(
        rawValue: NSWindow.Level.screenSaver.rawValue + 1
    )
}

/// Presents one transparent window per display and reports a rectangle in the global AppKit
/// screen coordinate space. The rectangle can cross display boundaries.
///
/// The visuals follow the area-picker pattern used by Screen Studio and the system screenshot
/// experience: dimmed screen, a thin high-contrast frame, quiet in-frame guides and a live size
/// badge. Releasing the pointer submits the rectangle immediately; advanced mode then opens the
/// editor, where any crop adjustment and annotation happen in one continuous capture flow.
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
    private var selectionRect: CGRect?
    private var dragStartPoint: CGPoint?
    private var adjustmentState: AnnotationScreenSelectionState?
    private var isCompletingSelection = false
    private var presentationID: UUID?
    private var screenUnionBounds: CGRect = .null
    private var cursorIsPushed = false
    private var keepsDimWhilePassive = false
    private var onSelection: SelectionHandler?
    private var onCancel: (() -> Void)?
    private var onAdjustmentPreview: ((CGRect) -> Void)?
    private var onAdjustmentCommit: ((CGRect) -> Void)?
    private var onAdjustmentComplete: ((CGRect) -> Void)?
    private weak var previouslyActiveApplication: NSRunningApplication?

    func present(
        keepsDimWhilePassive: Bool = false,
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
        self.keepsDimWhilePassive = keepsDimWhilePassive
        previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
        screenUnionBounds = NSScreen.screens.dropFirst().reduce(
            NSScreen.screens[0].frame
        ) { $0.union($1.frame) }
        NSCursor.crosshair.push()
        cursorIsPushed = true

        windows = NSScreen.screens.map { screen in
            let window = SelectionOverlayWindow(screen: screen)
            let view = SelectionOverlayView(
                frame: NSRect(origin: .zero, size: screen.frame.size)
            )
            view.keepsDimWhilePassive = keepsDimWhilePassive
            view.delegate = self
            window.contentView = view
            window.orderFrontRegardless()
            return window
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            switch event.keyCode {
            case 53:
                self?.cancel()
                return nil
            default:
                return event
            }
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
        if var state = adjustmentState {
            guard state.beginDrag(at: screenPoint) else { return }
            adjustmentState = state
            selectionRect = state.selection
            updateViews()
            return
        }

        guard !isCompletingSelection else { return }
        dragStartPoint = screenPoint
        selectionRect = nil
        updateViews()
    }

    fileprivate func selectionView(
        _ view: SelectionOverlayView,
        doubleClickedAt screenPoint: CGPoint
    ) {
        guard let state = adjustmentState,
              state.selection.contains(screenPoint),
              SelectionEdge.zone(
                  at: screenPoint,
                  in: state.selection,
                  padding: 16,
                  flipped: false
              ) == nil else { return }
        onAdjustmentComplete?(state.selection)
    }

    fileprivate func selectionView(_ view: SelectionOverlayView, movedTo screenPoint: CGPoint) {
        if var state = adjustmentState {
            guard let selection = state.updateDrag(to: screenPoint) else { return }
            adjustmentState = state
            selectionRect = selection
            updateViews()
            onAdjustmentPreview?(selection)
            return
        }

        guard !isCompletingSelection, let dragStartPoint else { return }
        let rect = SelectionGeometry.rectangle(from: dragStartPoint, to: screenPoint)
        let clamped = rect.intersection(screenUnionBounds)
        if !clamped.isNull {
            selectionRect = clamped
        }
        updateViews()
    }

    fileprivate func selectionView(_ view: SelectionOverlayView, endedAt screenPoint: CGPoint) {
        if var state = adjustmentState {
            guard state.isDragging else { return }
            _ = state.updateDrag(to: screenPoint)
            let selection = SelectionGeometry.captureAligned(
                state.endDrag(),
                within: screenUnionBounds
            )
            state.replaceSelection(selection)
            adjustmentState = state
            selectionRect = state.selection
            updateViews()
            onAdjustmentCommit?(state.selection)
            return
        }

        guard !isCompletingSelection, let dragStartPoint else { return }
        self.dragStartPoint = nil
        let rect = SelectionGeometry.rectangle(from: dragStartPoint, to: screenPoint)
        let selection = SelectionGeometry.captureAligned(
            rect,
            within: screenUnionBounds
        )
        guard !selection.isNull, selection.width >= 8, selection.height >= 8 else {
            selectionRect = nil
            NSSound.beep()
            updateViews()
            return
        }
        selectionRect = selection
        updateViews()
        // Selection and confirmation are deliberately one gesture. Advanced editing
        // starts after the capture returns; it is not a second confirmation step here.
        confirmSelection()
    }

    private func confirmSelection() {
        guard !isCompletingSelection,
              let selectionRect,
              selectionRect.width >= 8,
              selectionRect.height >= 8,
              let presentationID else { return }

        isCompletingSelection = true
        updateViews()
        onSelection?(
            selectionRect,
            { [weak self] in
                self?.activatePassiveFrame(presentationID: presentationID)
            },
            { [weak self] in
                self?.tearDown(presentationID: presentationID)
            }
        )
    }

    private func updateViews() {
        for window in windows {
            guard let view = window.contentView as? SelectionOverlayView else { continue }
            view.globalSelection = selectionRect
            view.selectionIsLocked = isCompletingSelection
        }
    }

    private func activatePassiveFrame(presentationID: UUID) {
        guard self.presentationID == presentationID, isPresenting else { return }
        removeEventMonitor()

        for window in windows {
            window.ignoresMouseEvents = true
            guard let view = window.contentView as? SelectionOverlayView else { continue }
            view.displayMode = .passiveFrame
        }

        discardSelectionCursor()
        restorePreviousApplication()
    }

    /// Promotes the original area picker into the editable selection surface.
    /// No window or selection chrome is replaced at mouse-up, so the mask,
    /// guides and handles cannot flash or leave a stale frame during handoff.
    func beginAdjustment(
        selection: CGRect,
        onPreview: @escaping (CGRect) -> Void,
        onCommit: @escaping (CGRect) -> Void,
        onComplete: @escaping (CGRect) -> Void
    ) {
        guard isPresenting else { return }
        let state = AnnotationScreenSelectionState(
            selection: selection,
            screenBounds: screenUnionBounds
        )
        adjustmentState = state
        selectionRect = state.selection
        dragStartPoint = nil
        isCompletingSelection = false
        onAdjustmentPreview = onPreview
        onAdjustmentCommit = onCommit
        onAdjustmentComplete = onComplete

        for window in windows {
            window.ignoresMouseEvents = false
            guard let view = window.contentView as? SelectionOverlayView else { continue }
            view.displayMode = .adjusting
        }
        updateViews()
        bringAdjustmentSurfaceToFront()
        windows.first?.makeKey()
    }

    func replaceAdjustmentSelection(_ selection: CGRect) {
        guard var state = adjustmentState else { return }
        state.replaceSelection(selection)
        adjustmentState = state
        selectionRect = state.selection
        updateViews()
    }

    func setAdjustmentInteractionEnabled(_ enabled: Bool) {
        guard adjustmentState != nil else { return }
        if !enabled {
            adjustmentState?.cancelDrag()
        }
        windows.forEach { $0.ignoresMouseEvents = !enabled }
        updateViews()
        if enabled {
            bringAdjustmentSurfaceToFront()
            windows.first?.makeKey()
        }
    }

    func bringAdjustmentSurfaceToFront() {
        guard adjustmentState != nil else { return }
        windows.forEach { $0.orderFrontRegardless() }
    }

    private func tearDown(presentationID: UUID) {
        guard self.presentationID == presentationID, isPresenting else { return }
        removeEventMonitor()

        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        selectionRect = nil
        dragStartPoint = nil
        adjustmentState = nil
        isCompletingSelection = false
        self.presentationID = nil
        onSelection = nil
        onCancel = nil
        onAdjustmentPreview = nil
        onAdjustmentCommit = nil
        onAdjustmentComplete = nil
        keepsDimWhilePassive = false
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

    static func captureAligned(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        let bounds = bounds.standardized
        let clamped = rect.standardized.intersection(bounds)
        guard !clamped.isNull else { return .null }
        return ScreenCaptureGeometry.alignedToPointGrid(clamped).intersection(bounds)
    }
}

@MainActor
fileprivate protocol SelectionOverlayViewDelegate: AnyObject {
    func selectionView(_ view: SelectionOverlayView, beganAt screenPoint: CGPoint)
    func selectionView(_ view: SelectionOverlayView, doubleClickedAt screenPoint: CGPoint)
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
        // Keep Clip visible to user-initiated system screenshots. The capture
        // engine excludes this process's windows from Clip's own output.
        sharingType = .readOnly
        level = AnnotationOverlayWindowLevel.selection
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
}

enum SelectionOverlayDisplayMode {
    case selecting
    case passiveFrame
    case adjusting
}

enum SelectionOverlayDimPolicy {
    static func opacity(
        displayMode: SelectionOverlayDisplayMode,
        keepsDimWhilePassive: Bool
    ) -> CGFloat {
        if displayMode == .passiveFrame, !keepsDimWhilePassive {
            return 0.12
        }
        return 0.40
    }
}

enum SelectionOverlayGuidePolicy {
    static let fractions: [CGFloat] = [0.25, 0.5, 0.75]

    static func showsGuides(
        displayMode: SelectionOverlayDisplayMode,
        selectionIsLocked: Bool,
        keepsDimWhilePassive: Bool
    ) -> Bool {
        switch displayMode {
        case .selecting:
            !selectionIsLocked || keepsDimWhilePassive
        case .passiveFrame:
            keepsDimWhilePassive
        case .adjusting:
            true
        }
    }

    static func showsHandles(
        displayMode: SelectionOverlayDisplayMode,
        selectionIsLocked: Bool,
        keepsDimWhilePassive: Bool
    ) -> Bool {
        showsGuides(
            displayMode: displayMode,
            selectionIsLocked: selectionIsLocked,
            keepsDimWhilePassive: keepsDimWhilePassive
        )
    }
}

@MainActor
fileprivate final class SelectionOverlayView: NSView {
    weak var delegate: SelectionOverlayViewDelegate?
    var keepsDimWhilePassive = false {
        didSet { updateOverlayLayers() }
    }
    var displayMode: SelectionOverlayDisplayMode = .selecting {
        didSet { updateOverlayLayers() }
    }
    var globalSelection: CGRect? {
        didSet { updateOverlayLayers() }
    }
    var selectionIsLocked = false {
        didSet { updateOverlayLayers() }
    }

    // All visuals are static CALayers; dragging only updates geometry, so the
    // render server composites each frame and the app never repaints pixels.
    // This is what keeps the frame glued to the pointer like the system UI.
    private let dimLayer = CALayer()
    private let dimMaskLayer = CAShapeLayer()
    private let borderContrastLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let guideContrastLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private let badgeLayer = SelectionBadgeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configureLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureLayers() {
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.40).cgColor
        dimMaskLayer.fillRule = .evenOdd
        dimLayer.mask = dimMaskLayer

        for strokeLayer in [
            borderContrastLayer,
            borderLayer,
            guideContrastLayer,
            guideLayer
        ] {
            strokeLayer.lineWidth = SelectionOverlayChromeStyle.lineWidth
            strokeLayer.lineDashPattern = SelectionOverlayChromeStyle.lineDashPattern
            strokeLayer.fillColor = NSColor.clear.cgColor
        }
        borderContrastLayer.strokeColor = NSColor.black.withAlphaComponent(
            SelectionOverlayChromeStyle.darkStrokeOpacity
        ).cgColor
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(
            SelectionOverlayChromeStyle.lightStrokeOpacity
        ).cgColor

        handleLayer.fillColor = NSColor.black.withAlphaComponent(0.94).cgColor
        handleLayer.strokeColor = NSColor.white.withAlphaComponent(0.94).cgColor
        handleLayer.lineWidth = 1

        guideContrastLayer.strokeColor = NSColor.black.withAlphaComponent(
            SelectionOverlayChromeStyle.darkStrokeOpacity
        ).cgColor
        guideLayer.strokeColor = NSColor.white.withAlphaComponent(
            SelectionOverlayChromeStyle.lightStrokeOpacity
        ).cgColor

        installSublayers()
    }

    /// The backing layer only exists reliably once the view is in a window;
    /// this is idempotent so it can run on every re-attachment.
    private func installSublayers() {
        guard let layer, dimLayer.superlayer == nil else { return }
        layer.addSublayer(dimLayer)
        layer.addSublayer(guideContrastLayer)
        layer.addSublayer(guideLayer)
        layer.addSublayer(borderContrastLayer)
        layer.addSublayer(borderLayer)
        layer.addSublayer(handleLayer)
        layer.addSublayer(badgeLayer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installSublayers()
        updateOverlayLayers()
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        addCursorRect(
            bounds,
            cursor: displayMode == .selecting ? .crosshair : .arrow
        )
    }

    override func mouseMoved(with event: NSEvent) {
        guard displayMode == .adjusting, let selection = globalSelection else {
            NSCursor.crosshair.set()
            return
        }
        let point = globalPoint(for: event)
        if let edge = SelectionEdge.zone(
            at: point,
            in: selection,
            padding: 16,
            flipped: false
        ) {
            edge.cursor().set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = globalPoint(for: event)
        if event.clickCount == 2 {
            delegate?.selectionView(self, doubleClickedAt: point)
        } else {
            delegate?.selectionView(self, beganAt: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        delegate?.selectionView(self, movedTo: globalPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        delegate?.selectionView(self, endedAt: globalPoint(for: event))
    }

    private func updateOverlayLayers() {
        guard layer != nil, dimLayer.superlayer != nil else { return }
        // Property changes must land the same frame; implicit animations would
        // make the frame trail behind the pointer.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let scale = window?.screen?.backingScaleFactor
            ?? window?.backingScaleFactor ?? 2
        dimLayer.frame = bounds
        let dimOpacity = SelectionOverlayDimPolicy.opacity(
            displayMode: displayMode,
            keepsDimWhilePassive: keepsDimWhilePassive
        )
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(dimOpacity).cgColor
        dimLayer.isHidden = dimOpacity <= 0
        dimMaskLayer.frame = CGRect(origin: .zero, size: bounds.size)
        dimMaskLayer.contentsScale = scale
        guideContrastLayer.contentsScale = scale
        guideLayer.contentsScale = scale
        borderContrastLayer.contentsScale = scale
        borderLayer.contentsScale = scale
        handleLayer.contentsScale = scale

        let localSelection: CGRect? = globalSelection.flatMap { selection in
            guard let window else { return nil }
            let windowSelection = window.convertFromScreen(selection)
            let local = convert(windowSelection, from: nil)
            return local.intersects(bounds) ? local : nil
        }

        let maskPath = CGMutablePath()
        maskPath.addRect(CGRect(origin: .zero, size: bounds.size))
        if !dimLayer.isHidden, let selection = localSelection {
            maskPath.addRect(selection)
        }
        dimMaskLayer.path = maskPath

        if let selection = localSelection {
            let borderPath = CGMutablePath()
            borderPath.addRect(selection.insetBy(dx: 0.5, dy: 0.5))
            borderContrastLayer.path = borderPath
            borderLayer.path = borderPath
            borderContrastLayer.isHidden = false
            borderLayer.isHidden = false

            let handlePath = CGMutablePath()
            let handleRadius = SelectionOverlayChromeStyle.handleDiameter / 2
            for edge in SelectionEdge.allCases {
                let center = edge.point(in: selection, flipped: false)
                handlePath.addEllipse(in: CGRect(
                    x: center.x - handleRadius,
                    y: center.y - handleRadius,
                    width: SelectionOverlayChromeStyle.handleDiameter,
                    height: SelectionOverlayChromeStyle.handleDiameter
                ))
            }
            handleLayer.path = handlePath
            let showHandles = SelectionOverlayGuidePolicy.showsHandles(
                displayMode: displayMode,
                selectionIsLocked: selectionIsLocked,
                keepsDimWhilePassive: keepsDimWhilePassive
            )
            handleLayer.isHidden = !showHandles
        } else {
            borderContrastLayer.isHidden = true
            borderLayer.isHidden = true
            handleLayer.isHidden = true
        }

        if displayMode == .selecting,
           let selection = localSelection,
           let globalSelection {
            let text = "\(Int(globalSelection.width * scale)) × \(Int(globalSelection.height * scale))"
            if let size = badgeLayer.render(text: text, scale: scale) {
                // The system screenshot UI centers the badge just below the
                // frame and moves it above when the bottom edge would fall
                // off-screen.
                var origin = NSPoint(
                    x: selection.midX - size.width / 2,
                    y: selection.minY - size.height - 6
                )
                if origin.y < bounds.minY + 6 {
                    origin.y = min(selection.maxY + 6, bounds.maxY - size.height - 6)
                }
                origin.x = min(
                    max(origin.x, bounds.minX + 6),
                    bounds.maxX - size.width - 6
                )
                badgeLayer.frame = NSRect(origin: origin, size: size)
                badgeLayer.isHidden = false
            }
        } else {
            badgeLayer.isHidden = true
        }

        let showGuides = SelectionOverlayGuidePolicy.showsGuides(
            displayMode: displayMode,
            selectionIsLocked: selectionIsLocked,
            keepsDimWhilePassive: keepsDimWhilePassive
        )
        if showGuides, let selection = localSelection {
            // Screen Studio divides the active area into sixteen quiet cells.
            // Keeping the grid after mouse-up makes adjustment feel like the
            // same selection rather than a second editing mode.
            let guidePath = CGMutablePath()
            for fraction in SelectionOverlayGuidePolicy.fractions {
                let x = selection.minX + selection.width * fraction
                guidePath.move(to: CGPoint(x: x, y: selection.minY))
                guidePath.addLine(to: CGPoint(x: x, y: selection.maxY))
                let y = selection.minY + selection.height * fraction
                guidePath.move(to: CGPoint(x: selection.minX, y: y))
                guidePath.addLine(to: CGPoint(x: selection.maxX, y: y))
            }
            guideContrastLayer.path = guidePath
            guideLayer.path = guidePath
            guideContrastLayer.isHidden = false
            guideLayer.isHidden = false
        } else {
            guideContrastLayer.isHidden = true
            guideLayer.isHidden = true
        }

    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}


/// A dark pill with monospaced white text, rendered into cached contents so
/// repeated frames with the same text never re-rasterize. The caller positions
/// the layer in its own coordinate space.
@MainActor
final class SelectionBadgeLayer: CALayer {
    private struct Cache {
        var text: String
        var scale: CGFloat
        var size: NSSize
    }

    private var cache: Cache?
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white
    ]

    /// Renders `text` into the layer contents and returns the pill size in
    /// points, or nil when rendering failed. Identical input reuses the cache.
    func render(text: String, scale: CGFloat) -> NSSize? {
        if let cached = cache, cached.text == text, cached.scale == scale {
            return cached.size
        }
        let textSize = text.size(withAttributes: Self.attributes)
        let pillSize = NSSize(width: ceil(textSize.width) + 14, height: 22)
        let pixelsWide = max(1, Int(pillSize.width * scale))
        let pixelsHigh = max(1, Int(pillSize.height * scale))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        representation.size = pillSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: pillSize), xRadius: 6, yRadius: 6).fill()
        text.draw(
            at: NSPoint(x: 7, y: (pillSize.height - textSize.height) / 2),
            withAttributes: Self.attributes
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let image = representation.cgImage else { return nil }
        contents = image
        contentsScale = scale
        contentsGravity = .center
        cache = Cache(text: text, scale: scale, size: pillSize)
        return pillSize
    }
}
