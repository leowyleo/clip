import AppKit

enum AnnotationCanvasCropMode {
    case canvasBounded
    case screenManaged
    case disabled

    var showsSelectionControls: Bool {
        self != .disabled
    }

    var cropsRenderedOutput: Bool {
        self != .disabled
    }

    var usesCanvasInteraction: Bool {
        self == .canvasBounded
    }

    var drawsCanvasChrome: Bool {
        self == .canvasBounded
    }
}

enum AnnotationScreenSelectionDragMode: Equatable {
    case moving
    case resizing(SelectionEdge)
}

/// The single source of truth for static-capture adjustment. Its coordinates
/// are global AppKit screen coordinates, so drawing and hit testing cannot
/// drift apart when the selection leaves the original captured window.
struct AnnotationScreenSelectionState {
    private(set) var selection: CGRect
    let screenBounds: CGRect
    private(set) var dragMode: AnnotationScreenSelectionDragMode?

    private var dragStartPoint: CGPoint?
    private var dragStartSelection: CGRect?

    init(selection: CGRect, screenBounds: CGRect) {
        self.screenBounds = screenBounds.standardized
        self.selection = selection.standardized.intersection(self.screenBounds)
    }

    var isDragging: Bool { dragMode != nil }

    mutating func replaceSelection(_ rect: CGRect) {
        selection = rect.standardized.intersection(screenBounds)
        cancelDrag()
    }

    @discardableResult
    mutating func beginDrag(at point: CGPoint, hitPadding: CGFloat = 16) -> Bool {
        let mode: AnnotationScreenSelectionDragMode
        if let edge = SelectionEdge.zone(
            at: point,
            in: selection,
            padding: hitPadding,
            flipped: false
        ) {
            mode = .resizing(edge)
        } else if selection.contains(point) {
            mode = .moving
        } else {
            cancelDrag()
            return false
        }

        dragMode = mode
        dragStartPoint = point
        dragStartSelection = selection
        return true
    }

    @discardableResult
    mutating func updateDrag(to point: CGPoint) -> CGRect? {
        guard let dragMode,
              let dragStartPoint,
              let original = dragStartSelection else { return nil }

        switch dragMode {
        case .moving:
            let proposedX = original.minX + point.x - dragStartPoint.x
            let proposedY = original.minY + point.y - dragStartPoint.y
            let maximumX = screenBounds.maxX - original.width
            let maximumY = screenBounds.maxY - original.height
            selection = CGRect(
                x: min(max(proposedX, screenBounds.minX), maximumX),
                y: min(max(proposedY, screenBounds.minY), maximumY),
                width: original.width,
                height: original.height
            )
        case .resizing(let edge):
            selection = edge.resizedRect(
                original: original,
                to: point,
                flipped: false,
                bounds: screenBounds
            )
        }
        return selection
    }

    @discardableResult
    mutating func endDrag() -> CGRect {
        let result = selection
        cancelDrag()
        return result
    }

    mutating func cancelDrag() {
        dragMode = nil
        dragStartPoint = nil
        dragStartSelection = nil
    }
}

@MainActor
protocol AnnotationScreenSelectionViewDelegate: AnyObject {
    func annotationScreenSelectionView(
        _ view: AnnotationScreenSelectionView,
        didPreview selection: CGRect
    )
    func annotationScreenSelectionView(
        _ view: AnnotationScreenSelectionView,
        didCommit selection: CGRect
    )
    func annotationScreenSelectionViewRequestedCompletion(
        _ view: AnnotationScreenSelectionView
    )
}

/// A single full-screen surface owns dimming, frame rendering, handles and
/// mouse input for static captures. Keeping those responsibilities together is
/// what prevents stale seams and visually editable-but-untouchable handles.
@MainActor
final class AnnotationScreenSelectionView: NSView {
    weak var delegate: AnnotationScreenSelectionViewDelegate?

    var isInteractionEnabled = true {
        didSet {
            if !isInteractionEnabled {
                state.cancelDrag()
                updateLayers()
            }
        }
    }

    private var state: AnnotationScreenSelectionState
    private var lastMousePoint: CGPoint?
    private let dimLayer = CALayer()
    private let dimMaskLayer = CAShapeLayer()
    private let borderShadowLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let handleShadowLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let activeHandleLayer = CAShapeLayer()
    private let badgeLayer = SelectionBadgeLayer()

    init(frame: CGRect, selection: CGRect, screenBounds: CGRect) {
        state = AnnotationScreenSelectionState(
            selection: selection,
            screenBounds: screenBounds
        )
        super.init(frame: frame)
        wantsLayer = true
        configureLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    var selection: CGRect { state.selection }

    func replaceSelection(_ selection: CGRect) {
        state.replaceSelection(selection)
        updateLayers()
        window?.invalidateCursorRects(for: self)
    }

    private func configureLayers() {
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        dimMaskLayer.fillRule = .evenOdd
        dimLayer.mask = dimMaskLayer

        borderShadowLayer.fillColor = NSColor.clear.cgColor
        borderShadowLayer.strokeColor = NSColor.black.withAlphaComponent(0.76).cgColor
        borderShadowLayer.lineWidth = 3
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.92).cgColor
        borderLayer.lineWidth = 1

        handleShadowLayer.fillColor = NSColor.black.withAlphaComponent(0.78).cgColor
        handleLayer.fillColor = NSColor.white.withAlphaComponent(0.94).cgColor
        handleLayer.strokeColor = NSColor.black.withAlphaComponent(0.42).cgColor
        handleLayer.lineWidth = 0.75
        activeHandleLayer.fillColor = NSColor.controlAccentColor.cgColor
        activeHandleLayer.strokeColor = NSColor.white.cgColor
        activeHandleLayer.lineWidth = 1

        installLayers()
    }

    private func installLayers() {
        guard let layer, dimLayer.superlayer == nil else { return }
        layer.addSublayer(dimLayer)
        layer.addSublayer(borderShadowLayer)
        layer.addSublayer(borderLayer)
        layer.addSublayer(handleShadowLayer)
        layer.addSublayer(handleLayer)
        layer.addSublayer(activeHandleLayer)
        layer.addSublayer(badgeLayer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installLayers()
        updateLayers()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = globalPoint(for: event)
        lastMousePoint = point
        if let edge = SelectionEdge.zone(
            at: point,
            in: state.selection,
            padding: 16,
            flipped: false
        ) {
            edge.cursor().set()
        } else if state.selection.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        window?.makeKey()
        let point = globalPoint(for: event)
        lastMousePoint = point

        if event.clickCount == 2,
           state.selection.contains(point),
           SelectionEdge.zone(
               at: point,
               in: state.selection,
               padding: 16,
               flipped: false
           ) == nil {
            delegate?.annotationScreenSelectionViewRequestedCompletion(self)
            return
        }

        guard state.beginDrag(at: point) else {
            // Outside clicks intentionally do nothing. This window remains the
            // active input surface, so the next handle drag still works.
            return
        }
        updateLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        let point = globalPoint(for: event)
        lastMousePoint = point
        guard let selection = state.updateDrag(to: point) else { return }
        updateLayers()
        delegate?.annotationScreenSelectionView(self, didPreview: selection)
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        guard state.isDragging else { return }
        _ = state.updateDrag(to: globalPoint(for: event))
        let selection = state.endDrag()
        updateLayers()
        delegate?.annotationScreenSelectionView(self, didCommit: selection)
    }

    private func updateLayers() {
        guard let window, let layer, dimLayer.superlayer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let scale = window.backingScaleFactor
        dimLayer.frame = bounds
        dimMaskLayer.frame = bounds
        dimMaskLayer.contentsScale = scale
        borderShadowLayer.contentsScale = scale
        borderLayer.contentsScale = scale
        handleShadowLayer.contentsScale = scale
        handleLayer.contentsScale = scale
        activeHandleLayer.contentsScale = scale

        let localSelection = localRect(for: state.selection)
        let mask = CGMutablePath()
        mask.addRect(bounds)
        mask.addRect(localSelection)
        dimMaskLayer.path = mask

        let border = CGPath(rect: localSelection.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        borderShadowLayer.path = border
        borderLayer.path = border

        let handles = CGMutablePath()
        let shadows = CGMutablePath()
        for edge in SelectionEdge.allCases {
            let center = edge.point(in: localSelection, flipped: false)
            handles.addEllipse(in: dotRect(at: center, radius: 4))
            shadows.addEllipse(in: dotRect(at: center, radius: 5))
        }
        handleLayer.path = handles
        handleShadowLayer.path = shadows

        if case .resizing(let edge) = state.dragMode {
            let center = edge.point(in: localSelection, flipped: false)
            activeHandleLayer.path = CGPath(
                ellipseIn: dotRect(at: center, radius: 5.5),
                transform: nil
            )
            activeHandleLayer.isHidden = false
        } else {
            activeHandleLayer.isHidden = true
        }

        if state.isDragging,
           let size = badgeLayer.render(
               text: "\(Int(state.selection.width * scale)) × \(Int(state.selection.height * scale))",
               scale: scale
           ) {
            var origin = CGPoint(
                x: localSelection.midX - size.width / 2,
                y: localSelection.minY - size.height - 6
            )
            if origin.y < bounds.minY + 6 {
                origin.y = min(localSelection.maxY + 6, bounds.maxY - size.height - 6)
            }
            origin.x = min(
                max(origin.x, bounds.minX + 6),
                bounds.maxX - size.width - 6
            )
            badgeLayer.frame = CGRect(origin: origin, size: size)
            badgeLayer.isHidden = false
        } else {
            badgeLayer.isHidden = true
        }

        layer.setNeedsDisplay()
    }

    private func localRect(for globalRect: CGRect) -> CGRect {
        guard let window else { return globalRect }
        let inWindow = window.convertFromScreen(globalRect)
        return convert(inWindow, from: nil)
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func dotRect(at center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }
}

@MainActor
final class AnnotationScreenSelectionWindow: NSWindow {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .readOnly
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
