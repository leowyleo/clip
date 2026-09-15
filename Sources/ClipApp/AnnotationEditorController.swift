import AppKit
import ClipCapture
import ClipCore
import CoreImage
import Vision

enum AnnotationTool: Int, CaseIterable {
    case mosaic
    case text
    case rectangle
    case ellipse
    case line
    case arrow
}

enum AnnotationShapeKind: Equatable {
    case rectangle
    case ellipse
}

struct MosaicAnnotation: Equatable {
    var points: [CGPoint]
    var width: CGFloat
}

struct TextAnnotation: Equatable {
    var text: String
    var origin: CGPoint
}

struct ShapeAnnotation: Equatable {
    var kind: AnnotationShapeKind
    var rect: CGRect
}

struct LineAnnotation: Equatable {
    var start: CGPoint
    var end: CGPoint
    var hasArrowhead: Bool
}

enum AnnotationElement: Equatable {
    case mosaic(MosaicAnnotation)
    case text(TextAnnotation)
    case shape(ShapeAnnotation)
    case line(LineAnnotation)
}

struct AnnotationDocument: Equatable {
    private(set) var elements: [AnnotationElement] = []

    mutating func append(_ element: AnnotationElement) {
        elements.append(element)
    }

    @discardableResult
    mutating func undo() -> AnnotationElement? {
        elements.popLast()
    }
}

enum AnnotationGeometry {
    static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        ).standardized
    }

    static func canvasSize(
        imageSize: CGSize,
        viewportSize: CGSize
    ) -> CGSize {
        guard imageSize.width > 0,
              imageSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return viewportSize
        }
        let scaledHeight = imageSize.height * viewportSize.width / imageSize.width
        return CGSize(width: viewportSize.width, height: max(1, scaledHeight))
    }

    static func pixelCropRect(
        for canvasRect: CGRect,
        canvasSize: CGSize,
        imageSize: CGSize
    ) -> CGRect {
        guard canvasSize.width > 0,
              canvasSize.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return .null
        }

        let scaleX = imageSize.width / canvasSize.width
        let scaleY = imageSize.height / canvasSize.height
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: imageSize.width,
            height: imageSize.height
        )
        let minX = floor(canvasRect.minX * scaleX)
        let maxX = ceil(canvasRect.maxX * scaleX)
        let minY = floor((canvasSize.height - canvasRect.maxY) * scaleY)
        let maxY = ceil((canvasSize.height - canvasRect.minY) * scaleY)

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ).intersection(imageBounds)
    }

    static func movedCropRect(
        original: CGRect,
        by delta: CGSize,
        within bounds: CGRect
    ) -> CGRect {
        let x = min(
            max(original.minX + delta.width, bounds.minX),
            bounds.maxX - original.width
        )
        let y = min(
            max(original.minY + delta.height, bounds.minY),
            bounds.maxY - original.height
        )
        return CGRect(x: x, y: y, width: original.width, height: original.height)
    }

    static func movedCropRect(
        original: CGRect,
        by delta: CGSize
    ) -> CGRect {
        CGRect(
            x: original.minX + delta.width,
            y: original.minY + delta.height,
            width: original.width,
            height: original.height
        )
    }
}

enum AnnotationEditorResult {
    case image(CGImage)
    case ocrTextCopied
}

enum AnnotationCropDragMode {
    case drawing
    case moving
    case resizing(SelectionEdge)
}

/// A crop frame may leave the captured image on purpose: the part that falls
/// outside the image stands for screen pixels Clip re-captures on mouse-up.
extension AnnotationCanvasView {
    static let cropExtensionTolerance: CGFloat = 1
}

extension AnnotationDocument {
    func mappingElements(
        _ transform: (AnnotationElement) -> AnnotationElement
    ) -> AnnotationDocument {
        var copy = AnnotationDocument()
        for element in elements {
            copy.append(transform(element))
        }
        return copy
    }
}

extension AnnotationElement {
    /// Shifts an element into the coordinate space of a crop that expanded
    /// toward the top or left of the original capture.
    func translated(by delta: CGPoint) -> AnnotationElement {
        switch self {
        case .mosaic(let annotation):
            return .mosaic(MosaicAnnotation(
                points: annotation.points.map {
                    CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
                },
                width: annotation.width
            ))
        case .text(let annotation):
            return .text(TextAnnotation(
                text: annotation.text,
                origin: CGPoint(x: annotation.origin.x + delta.x, y: annotation.origin.y + delta.y)
            ))
        case .shape(let annotation):
            return .shape(ShapeAnnotation(
                kind: annotation.kind,
                rect: annotation.rect.offsetBy(dx: delta.x, dy: delta.y)
            ))
        case .line(let annotation):
            return .line(LineAnnotation(
                start: CGPoint(x: annotation.start.x + delta.x, y: annotation.start.y + delta.y),
                end: CGPoint(x: annotation.end.x + delta.x, y: annotation.end.y + delta.y),
                hasArrowhead: annotation.hasArrowhead
            ))
        }
    }
}

@MainActor
protocol AnnotationCanvasViewDelegate: AnyObject {
    func annotationCanvas(_ canvas: AnnotationCanvasView, requestedTextAt point: CGPoint)
    func annotationCanvasRequestedCompletion(_ canvas: AnnotationCanvasView)
    func annotationCanvas(_ canvas: AnnotationCanvasView, didAdjustCropTo rect: CGRect)
    func annotationCanvas(_ canvas: AnnotationCanvasView, didChangeCropPreviewTo rect: CGRect?)
    func annotationCanvas(_ canvas: AnnotationCanvasView, requestedCropExtensionTo rect: CGRect)
}

@MainActor
final class AnnotationCanvasView: NSView {
    weak var delegate: AnnotationCanvasViewDelegate?

    private(set) var document = AnnotationDocument()
    private(set) var tool: AnnotationTool?

    private let baseImage: CGImage?
    private lazy var pixelatedNSImage = makePixelatedImage()
    private var liveMosaicPreview: (image: NSImage, rect: CGRect)?
    private var interactionRect: CGRect?

    private var workingMosaicPoints: [CGPoint] = []
    private var workingShapeStart: CGPoint?
    private var workingShapeEnd: CGPoint?
    private var workingLineStart: CGPoint?
    private var workingLineEnd: CGPoint?
    private var cropDragMode: AnnotationCropDragMode?
    private var cropDragStartPoint: CGPoint?
    private var cropDragStartRect: CGRect?
    private var workingCropRect: CGRect?
    private(set) var cropRect: CGRect?
    private var isRenderingOutput = false
    private let allowsCropExpansion: Bool
    private let cropMode: AnnotationCanvasCropMode
    private var lastMouseMovePoint: CGPoint?
    private let imageBackingView: ImageBackingView
    private let overlayView: OverlayView
    private let cropOverlayView = CropOverlayView(frame: .zero)
    private var didStartCropEditing = false
    private var lastCommittedCrop: CGRect?
    private var activeCropEdge: SelectionEdge?

    private static let cropHitPadding: CGFloat = 16

    init(
        image: CGImage,
        frame: CGRect,
        allowsCropExpansion: Bool = false,
        cropMode: AnnotationCanvasCropMode = .canvasBounded
    ) {
        baseImage = image
        self.allowsCropExpansion = allowsCropExpansion
        self.cropMode = cropMode

        let backing = ImageBackingView(frame: frame)
        imageBackingView = backing
        let overlay = OverlayView(frame: frame)
        overlayView = overlay

        super.init(frame: frame)
        cropRect = cropMode.cropsRenderedOutput ? bounds : nil
        lastCommittedCrop = cropRect
        wantsLayer = true
        layer?.masksToBounds = true

        overlay.canvas = self
        overlay.autoresizingMask = [.width, .height]
        backing.autoresizingMask = [.width, .height]
        cropOverlayView.autoresizingMask = [.width, .height]
        addSubview(backing)
        addSubview(overlay)
        addSubview(cropOverlayView)
        syncImageLayer()
        updateCropOverlay()
    }

    /// A transparent, screen-sized annotation surface. Static advanced capture
    /// uses this instead of presenting a frozen screenshot after mouse-up.
    init(liveFrame frame: CGRect) {
        baseImage = nil
        allowsCropExpansion = false
        cropMode = .disabled

        let backing = ImageBackingView(frame: frame)
        imageBackingView = backing
        let overlay = OverlayView(frame: frame)
        overlayView = overlay

        super.init(frame: frame)
        cropRect = nil
        lastCommittedCrop = nil
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        overlay.canvas = self
        overlay.autoresizingMask = [.width, .height]
        backing.autoresizingMask = [.width, .height]
        cropOverlayView.autoresizingMask = [.width, .height]
        addSubview(backing)
        addSubview(overlay)
        addSubview(cropOverlayView)
        updateCropOverlay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func setTool(_ tool: AnnotationTool?) {
        cancelWorkingElement()
        self.tool = tool
        window?.invalidateCursorRects(for: self)
        updateCropOverlay()
    }

    func appendText(_ text: String, at origin: CGPoint) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        document.append(.text(TextAnnotation(text: trimmed, origin: origin)))
        needsDisplay = true
    }

    func undo() {
        cancelWorkingElement()
        _ = document.undo()
        needsDisplay = true
    }

    func setDocument(_ document: AnnotationDocument) {
        self.document = document
        needsDisplay = true
    }

    func setInteractionRect(_ rect: CGRect?) {
        interactionRect = rect?.standardized.intersection(bounds)
        needsDisplay = true
    }

    func setLiveMosaicPreview(_ image: CGImage, in rect: CGRect) {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(14, forKey: kCIInputScaleKey)
        filter.setValue(
            CIVector(x: input.extent.midX, y: input.extent.midY),
            forKey: kCIInputCenterKey
        )
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let pixelated = CIContext(options: [.cacheIntermediates: false]).createCGImage(
                output,
                from: input.extent
              ) else { return }
        liveMosaicPreview = (NSImage(cgImage: pixelated, size: rect.size), rect)
        needsDisplay = true
    }

    func renderedImage() -> CGImage? {
        layoutSubtreeIfNeeded()
        guard let baseImage,
              bounds.width > 0,
              bounds.height > 0,
              let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: baseImage.width,
                pixelsHigh: baseImage.height,
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

        representation.size = bounds.size
        isRenderingOutput = true
        // The crop frame is UI, not capture content.
        cropOverlayView.isHidden = true
        defer {
            isRenderingOutput = false
            cropOverlayView.isHidden = false
        }
        cacheDisplay(in: bounds, to: representation)
        guard let renderedImage = representation.cgImage else { return nil }
        guard let cropRect else { return renderedImage }
        let pixelRect = AnnotationGeometry.pixelCropRect(
            for: cropRect,
            canvasSize: bounds.size,
            imageSize: CGSize(
                width: baseImage.width,
                height: baseImage.height
            )
        )
        guard
              !pixelRect.isNull,
              !pixelRect.isEmpty else {
            return renderedImage
        }
        return renderedImage.cropping(to: pixelRect) ?? renderedImage
    }

    func sourceImage() -> CGImage? {
        baseImage
    }

    /// Static region editing draws the selection chrome in screen space so
    /// handles can remain visible beyond the captured image. Scrolling results
    /// keep the chrome inside their scrollable image canvas instead.
    func setUsesScreenSelectionPreview(_ enabled: Bool) {
        cropOverlayView.drawsSelectionChrome = !enabled
        updateCropOverlay()
    }

    func setManagedCropRect(_ rect: CGRect) {
        guard cropMode.cropsRenderedOutput else { return }
        let crop = rect.standardized.intersection(bounds)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { return }
        cropRect = crop
        lastCommittedCrop = crop
        updateCropOverlay()
    }

    /// Installs state carried over from a previous canvas after the crop grew
    /// past the original capture and the image was re-captured.
    func restore(document: AnnotationDocument, cropRect: CGRect) {
        self.document = document
        self.cropRect = cropRect.intersection(bounds)
        lastCommittedCrop = self.cropRect
        updateCropOverlay()
        needsDisplay = true
    }

    /// The captured image lives in a GPU-backed layer; redraws (drags, tool
    /// strokes, scrolling) only touch the annotation overlay above it.
    override var needsDisplay: Bool {
        get { overlayView.needsDisplay }
        set { overlayView.needsDisplay = newValue }
    }

    private func syncImageLayer() {
        imageBackingView.wantsLayer = true
        guard let layer = imageBackingView.layer, bounds.width > 0 else { return }
        guard let baseImage else {
            layer.contents = nil
            layer.backgroundColor = NSColor.clear.cgColor
            return
        }
        layer.contents = baseImage
        layer.contentsGravity = .resize
        // Exact pixel-per-point mapping keeps the GPU from resampling per frame.
        layer.contentsScale = max(1, CGFloat(baseImage.width) / bounds.width)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncImageLayer()
        updateCropOverlay()
    }

    /// Pushes the current crop frame into the GPU-layer overlay. Crop-only
    /// changes never touch the annotation layer below.
    private func updateCropOverlay() {
        let pixelScale = bounds.width > 0
            ? CGFloat(baseImage?.width ?? 1) / bounds.width
            : 1
        cropOverlayView.update(
            selection: workingCropRect ?? cropRect,
            isDragging: workingCropRect != nil,
            showsHint: !didStartCropEditing && tool == nil,
            activeEdge: activeCropEdge,
            pixelScale: pixelScale,
            containerBounds: bounds
        )
        cropOverlayView.isHidden = isRenderingOutput || !cropMode.drawsCanvasChrome
    }

    private func updateExternalCropPreview(_ rect: CGRect?) {
        delegate?.annotationCanvas(self, didChangeCropPreviewTo: rect)
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch tool {
        case .text?:
            cursor = .iBeam
        case .mosaic?, .rectangle?, .ellipse?, .line?, .arrow?:
            cursor = .crosshair
        case nil:
            cursor = cropMode.usesCanvasInteraction
                ? cropCursor(at: lastMouseMovePoint)
                : .arrow
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseMoved(with event: NSEvent) {
        lastMouseMovePoint = localPoint(for: event)
        if tool == nil {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = localPoint(for: event)
        guard bounds.contains(point) else { return }
        if tool != nil, let interactionRect, !interactionRect.contains(point) {
            return
        }

        if tool == nil, event.clickCount == 2 {
            guard cropMode.usesCanvasInteraction else {
                delegate?.annotationCanvasRequestedCompletion(self)
                return
            }
            // A double-click on a handle or edge starts an adjustment instead
            // of finishing the capture.
            if case .resize = cropHit(at: point) {
                // Fall through to the crop-drag handling below.
            } else {
                delegate?.annotationCanvasRequestedCompletion(self)
                return
            }
        }

        switch tool {
        case .mosaic?:
            workingMosaicPoints = [point]
            needsDisplay = true
        case .text?:
            delegate?.annotationCanvas(self, requestedTextAt: point)
        case .rectangle?, .ellipse?:
            workingShapeStart = point
            workingShapeEnd = point
            needsDisplay = true
        case .line?, .arrow?:
            workingLineStart = point
            workingLineEnd = point
            needsDisplay = true
        case nil:
            guard cropMode.usesCanvasInteraction else { return }
            let hit = cropHit(at: point)
            switch hit {
            case .outside:
                // The initial screen gesture already created the capture. In
                // editor mode an outside click is intentionally a no-op; a
                // zero-sized working crop would hide the committed frame.
                return
            case .move:
                cropDragMode = .moving
                cropDragStartRect = cropRect
                workingCropRect = cropRect
            case .resize(let handle):
                cropDragMode = .resizing(handle)
                cropDragStartRect = cropRect
                workingCropRect = cropRect
            }
            activeCropEdge = {
                if case .resize(let edge) = hit { return edge }
                return nil
            }()
            cropDragStartPoint = point
            didStartCropEditing = true
            updateCropOverlay()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let rawPoint = localPoint(for: event)
        switch tool {
        case .mosaic?:
            guard !workingMosaicPoints.isEmpty else { return }
            let point = clamped(rawPoint)
            if let previous = workingMosaicPoints.last,
               hypot(point.x - previous.x, point.y - previous.y) < 1.5 {
                return
            }
            workingMosaicPoints.append(point)
            needsDisplay = true
        case .rectangle?, .ellipse?:
            guard workingShapeStart != nil else { return }
            workingShapeEnd = clamped(rawPoint)
            needsDisplay = true
        case .line?, .arrow?:
            guard workingLineStart != nil else { return }
            workingLineEnd = clamped(rawPoint)
            needsDisplay = true
        case nil:
            guard cropMode.usesCanvasInteraction else { return }
            guard let cropDragMode, let cropDragStartPoint else { return }
            switch cropDragMode {
            case .drawing:
                workingCropRect = AnnotationGeometry.rectangle(
                    from: cropDragStartPoint,
                    to: clamped(rawPoint)
                )
            case .moving:
                guard let original = cropDragStartRect else { return }
                let delta = CGSize(
                    width: rawPoint.x - cropDragStartPoint.x,
                    height: rawPoint.y - cropDragStartPoint.y
                )
                workingCropRect = allowsCropExpansion
                    ? AnnotationGeometry.movedCropRect(original: original, by: delta)
                    : AnnotationGeometry.movedCropRect(
                        original: original,
                        by: delta,
                        within: bounds
                    )
            case .resizing(let edge):
                guard let original = cropDragStartRect else { return }
                // Without bounds the frame may grow past the captured image; the
                // part outside stands for screen pixels re-captured on mouse-up.
                workingCropRect = edge.resizedRect(
                    original: original,
                    to: rawPoint,
                    flipped: true,
                    bounds: allowsCropExpansion ? nil : bounds
                )
            }
            updateCropOverlay()
            let preview = allowsCropExpansion
                ? workingCropRect
                : nil
            updateExternalCropPreview(preview)
        case .text?:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = clamped(localPoint(for: event))
        switch tool {
        case .mosaic?:
            guard !workingMosaicPoints.isEmpty else { return }
            workingMosaicPoints.append(point)
            document.append(.mosaic(MosaicAnnotation(
                points: workingMosaicPoints,
                width: 30
            )))
            workingMosaicPoints = []
            needsDisplay = true
        case .rectangle?, .ellipse?:
            guard let start = workingShapeStart else { return }
            let rect = AnnotationGeometry.rectangle(from: start, to: point)
            workingShapeStart = nil
            workingShapeEnd = nil
            guard rect.width >= 3, rect.height >= 3 else {
                needsDisplay = true
                return
            }
            let kind: AnnotationShapeKind = tool == .rectangle ? .rectangle : .ellipse
            document.append(.shape(ShapeAnnotation(kind: kind, rect: rect)))
            needsDisplay = true
        case .line?, .arrow?:
            guard let start = workingLineStart else { return }
            workingLineStart = nil
            workingLineEnd = nil
            guard hypot(point.x - start.x, point.y - start.y) >= 4 else {
                needsDisplay = true
                return
            }
            document.append(.line(LineAnnotation(
                start: start,
                end: point,
                hasArrowhead: tool == .arrow
            )))
            needsDisplay = true
        case nil:
            guard cropMode.usesCanvasInteraction else { return }
            guard let rect = workingCropRect else {
                clearCropDrag()
                return
            }
            // Do not briefly restore `cropRect` here. That intermediate update
            // paints the old frame for one run-loop turn before the committed
            // frame is installed, which is the stale outline seen after a drag.
            clearCropDrag(updateOverlay: false)
            guard rect.width >= 8, rect.height >= 8 else {
                updateExternalCropPreview(allowsCropExpansion ? cropRect : nil)
                updateCropOverlay()
                return
            }
            let standardized = rect.standardized
            if allowsCropExpansion, extendsBeyondCanvas(standardized) {
                // Commit right away so the frame hugs the edge the user dragged
                // to; if the re-capture fails, revertCropExtension puts the
                // previous frame back.
                cropRect = standardized
                updateCropOverlay()
                updateExternalCropPreview(standardized)
                delegate?.annotationCanvas(self, requestedCropExtensionTo: standardized)
                return
            }
            let newCrop = standardized.intersection(bounds)
            let changed = newCrop != lastCommittedCrop
            cropRect = newCrop
            lastCommittedCrop = newCrop
            updateExternalCropPreview(allowsCropExpansion ? newCrop : nil)
            updateCropOverlay()
            // Only report real adjustments; a bare handle click stays silent.
            if changed {
                delegate?.annotationCanvas(self, didAdjustCropTo: newCrop)
            }
        case .text?:
            break
        }
    }

    /// Restores the last committed frame after a failed crop extension.
    func revertCropExtension() {
        guard let lastCommittedCrop else { return }
        cropRect = lastCommittedCrop
        updateExternalCropPreview(allowsCropExpansion ? lastCommittedCrop : nil)
        updateCropOverlay()
    }

    /// Runs inside the overlay subview's drawing context; `bounds` here belong
    /// to the canvas, which shares the overlay's frame.
    func drawAnnotations() {
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        if let interactionRect {
            context?.clip(to: interactionRect)
        }
        defer { context?.restoreGState() }

        for element in document.elements {
            draw(element)
        }

        if !workingMosaicPoints.isEmpty {
            drawMosaic(points: workingMosaicPoints, width: 30)
        }
        if let start = workingShapeStart, let end = workingShapeEnd {
            let kind: AnnotationShapeKind = tool == .ellipse ? .ellipse : .rectangle
            drawShape(ShapeAnnotation(
                kind: kind,
                rect: AnnotationGeometry.rectangle(from: start, to: end)
            ))
        }
        if let start = workingLineStart, let end = workingLineEnd {
            drawLine(LineAnnotation(
                start: start,
                end: end,
                hasArrowhead: tool == .arrow
            ))
        }
    }

    private func draw(_ element: AnnotationElement) {
        switch element {
        case .mosaic(let annotation):
            drawMosaic(points: annotation.points, width: annotation.width)
        case .text(let annotation):
            drawText(annotation)
        case .shape(let annotation):
            drawShape(annotation)
        case .line(let annotation):
            drawLine(annotation)
        }
    }

    private func drawMosaic(points: [CGPoint], width: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let first = points.first else { return }

        context.saveGState()
        context.beginPath()
        context.move(to: first)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        if points.count == 1 {
            context.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
        }
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        if let pixelatedNSImage {
            pixelatedNSImage.draw(
                in: bounds,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        } else if let liveMosaicPreview {
            liveMosaicPreview.image.draw(
                in: liveMosaicPreview.rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
        context.restoreGState()
    }

    private func drawText(_ annotation: TextAnnotation) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
        shadow.shadowOffset = NSSize(width: 0, height: 1)
        shadow.shadowBlurRadius = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.systemRed,
            .shadow: shadow
        ]
        (annotation.text as NSString).draw(at: annotation.origin, withAttributes: attributes)
    }

    private func drawShape(_ annotation: ShapeAnnotation) {
        let rect = annotation.rect.insetBy(dx: 1.5, dy: 1.5)
        guard rect.width > 0, rect.height > 0 else { return }
        let path: NSBezierPath
        switch annotation.kind {
        case .rectangle:
            path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        case .ellipse:
            path = NSBezierPath(ovalIn: rect)
        }
        path.lineWidth = 3
        NSColor.systemRed.setStroke()
        path.stroke()
    }

    private func drawLine(_ annotation: LineAnnotation) {
        let path = NSBezierPath()
        path.move(to: annotation.start)
        path.line(to: annotation.end)
        path.lineWidth = 3
        path.lineCapStyle = .round
        NSColor.systemRed.setStroke()
        path.stroke()

        guard annotation.hasArrowhead else { return }
        let angle = atan2(
            annotation.end.y - annotation.start.y,
            annotation.end.x - annotation.start.x
        )
        let length: CGFloat = 13
        let spread: CGFloat = .pi / 7
        let left = CGPoint(
            x: annotation.end.x - length * cos(angle - spread),
            y: annotation.end.y - length * sin(angle - spread)
        )
        let right = CGPoint(
            x: annotation.end.x - length * cos(angle + spread),
            y: annotation.end.y - length * sin(angle + spread)
        )
        let head = NSBezierPath()
        head.move(to: annotation.end)
        head.line(to: left)
        head.line(to: right)
        head.close()
        NSColor.systemRed.setFill()
        head.fill()
    }

    private func makePixelatedImage() -> NSImage? {
        guard let baseImage else { return nil }
        let input = CIImage(cgImage: baseImage)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(14, forKey: kCIInputScaleKey)
        filter.setValue(
            CIVector(x: input.extent.midX, y: input.extent.midY),
            forKey: kCIInputCenterKey
        )
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let image = CIContext(options: [.cacheIntermediates: false]).createCGImage(
                output,
                from: input.extent
              ) else {
            return nil
        }
        return NSImage(cgImage: image, size: bounds.size)
    }

    private func cancelWorkingElement() {
        workingMosaicPoints = []
        workingShapeStart = nil
        workingShapeEnd = nil
        workingLineStart = nil
        workingLineEnd = nil
        updateExternalCropPreview(allowsCropExpansion ? cropRect : nil)
        clearCropDrag()
        needsDisplay = true
    }

    private func clearCropDrag(updateOverlay: Bool = true) {
        cropDragMode = nil
        cropDragStartPoint = nil
        cropDragStartRect = nil
        workingCropRect = nil
        activeCropEdge = nil
        if updateOverlay {
            updateCropOverlay()
        }
    }

    private func cropHit(at point: CGPoint) -> AnnotationCropHit {
        guard let cropRect else { return .outside }
        if let edge = SelectionEdge.zone(
            at: point,
            in: cropRect,
            padding: Self.cropHitPadding,
            flipped: true
        ) {
            return .resize(edge)
        }
        return cropRect.contains(point) ? .move : .outside
    }

    private func extendsBeyondCanvas(_ rect: CGRect) -> Bool {
        let tolerance = Self.cropExtensionTolerance
        return rect.minX < bounds.minX - tolerance
            || rect.minY < bounds.minY - tolerance
            || rect.maxX > bounds.maxX + tolerance
            || rect.maxY > bounds.maxY + tolerance
    }

    private func cropCursor(at point: CGPoint?) -> NSCursor {
        guard let cropRect, let point else { return .crosshair }
        if let edge = SelectionEdge.zone(
            at: point,
            in: cropRect,
            padding: Self.cropHitPadding,
            flipped: true
        ) {
            return edge.cursor()
        }
        return cropRect.contains(point) ? .arrow : .crosshair
    }

    private func localPoint(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let limits = interactionRect ?? bounds
        return CGPoint(
            x: min(max(point.x, limits.minX), limits.maxX),
            y: min(max(point.y, limits.minY), limits.maxY)
        )
    }

    /// Hosts the captured image as raw layer contents and never takes part in
    /// event hit-testing.
    final class ImageBackingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Draws annotations and the crop frame above the image layer; events pass
    /// through to the canvas.
    final class OverlayView: NSView {
        weak var canvas: AnnotationCanvasView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            canvas?.drawAnnotations()
        }
    }

    /// The crop frame as pure CALayers: shade, border, handles, size badge and
    /// a first-use hint. Updating it never repaints image or annotation pixels,
    /// which is what keeps frame drags glued to the pointer.
    final class CropOverlayView: NSView {
        private let shadeLayer = CALayer()
        private let shadeMaskLayer = CAShapeLayer()
        private let borderLayer = CAShapeLayer()
        private let handlesLayer = CAShapeLayer()
        private let activeHandleLayer = CAShapeLayer()
        private let badgeLayer = SelectionBadgeLayer()
        private let hintLayer = SelectionBadgeLayer()
        var drawsSelectionChrome = true

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true

            shadeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
            shadeMaskLayer.fillRule = .evenOdd
            shadeLayer.mask = shadeMaskLayer

            borderLayer.lineWidth = 1
            borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.75).cgColor
            borderLayer.fillColor = NSColor.clear.cgColor
            borderLayer.lineDashPattern = [4, 4]

            handlesLayer.fillColor = NSColor.black.withAlphaComponent(0.75).cgColor
            handlesLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
            handlesLayer.lineWidth = 1.5

            activeHandleLayer.fillColor = NSColor.white.withAlphaComponent(0.95).cgColor
            activeHandleLayer.strokeColor = NSColor.black.withAlphaComponent(0.4).cgColor
            activeHandleLayer.lineWidth = 1

            installSublayers()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// The backing layer only exists reliably once the view is in a window;
        /// this is idempotent so it can run on every re-attachment.
        private func installSublayers() {
            guard let layer, shadeLayer.superlayer == nil else { return }
            layer.addSublayer(shadeLayer)
            layer.addSublayer(borderLayer)
            layer.addSublayer(handlesLayer)
            layer.addSublayer(activeHandleLayer)
            layer.addSublayer(badgeLayer)
            layer.addSublayer(hintLayer)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installSublayers()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override var isFlipped: Bool { true }

        /// All geometry is in the flipped canvas coordinate space.
        func update(
            selection: CGRect?,
            isDragging: Bool,
            showsHint: Bool,
            activeEdge: SelectionEdge?,
            pixelScale: CGFloat,
            containerBounds: NSRect
        ) {
            guard shadeLayer.superlayer != nil, let window else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            let scale = window.backingScaleFactor
            shadeLayer.frame = containerBounds
            shadeMaskLayer.frame = CGRect(origin: .zero, size: containerBounds.size)
            shadeMaskLayer.contentsScale = scale
            borderLayer.contentsScale = scale
            handlesLayer.contentsScale = scale
            activeHandleLayer.contentsScale = scale

            guard let selection,
                  !selection.isNull,
                  selection.width >= 2,
                  selection.height >= 2 else {
                shadeMaskLayer.path = CGPath(rect: containerBounds, transform: nil)
                borderLayer.isHidden = true
                handlesLayer.isHidden = true
                activeHandleLayer.isHidden = true
                badgeLayer.isHidden = true
                hintLayer.isHidden = true
                return
            }

            let maskPath = CGMutablePath()
            maskPath.addRect(CGRect(origin: .zero, size: containerBounds.size))
            maskPath.addRect(selection)
            shadeMaskLayer.path = maskPath

            let borderPath = CGMutablePath()
            borderPath.addRect(selection)
            borderLayer.path = borderPath
            borderLayer.isHidden = !drawsSelectionChrome

            guard drawsSelectionChrome else {
                handlesLayer.isHidden = true
                activeHandleLayer.isHidden = true
                badgeLayer.isHidden = true
                hintLayer.isHidden = true
                return
            }

            borderLayer.isHidden = false

            let handlesPath = CGMutablePath()
            for edge in SelectionEdge.allCases {
                handlesPath.addEllipse(in: Self.dotRect(
                    at: edge.point(in: selection, flipped: true),
                    radius: Self.handleRadius
                ))
            }
            handlesLayer.path = handlesPath
            handlesLayer.isHidden = false

            // The grabbed dot reads larger and brighter — the tactile response
            // to pressing down on the frame.
            if let activeEdge {
                let activePath = CGMutablePath()
                activePath.addEllipse(in: Self.dotRect(
                    at: activeEdge.point(in: selection, flipped: true),
                    radius: Self.activeHandleRadius
                ))
                activeHandleLayer.path = activePath
                activeHandleLayer.isHidden = false
            } else {
                activeHandleLayer.isHidden = true
            }

            // The badge hugs the frame's lower edge and jumps above it when the
            // bottom would fall off-screen.
            if isDragging,
               let size = badgeLayer.render(
                   text: "\(Int(selection.width * pixelScale + 0.5)) × \(Int(selection.height * pixelScale + 0.5))",
                   scale: scale
               ) {
                var origin = NSPoint(
                    x: selection.midX - size.width / 2,
                    y: selection.maxY + 6
                )
                if origin.y + size.height > containerBounds.maxY - 6 {
                    origin.y = selection.minY - size.height - 6
                }
                origin.x = min(
                    max(origin.x, containerBounds.minX + 6),
                    containerBounds.maxX - size.width - 6
                )
                badgeLayer.frame = NSRect(origin: origin, size: size)
                badgeLayer.isHidden = false
            } else {
                badgeLayer.isHidden = true
            }

            if showsHint,
               let size = hintLayer.render(
                   text: ClipLocalization.text(
                       "Drag dots · drag outward to extend",
                       "拖动圆点调整 · 向外拖可扩展"
                   ),
                   scale: scale
               ) {
                var origin = NSPoint(
                    x: selection.midX - size.width / 2,
                    y: selection.minY + 10
                )
                origin.y = min(
                    max(origin.y, containerBounds.minY + 6),
                    containerBounds.maxY - size.height - 6
                )
                origin.x = min(
                    max(origin.x, containerBounds.minX + 6),
                    containerBounds.maxX - size.width - 6
                )
                hintLayer.frame = NSRect(origin: origin, size: size)
                hintLayer.isHidden = false
            } else {
                hintLayer.isHidden = true
            }
        }

        private static let handleRadius: CGFloat = 4
        private static let activeHandleRadius: CGFloat = 5.5

        private static func dotRect(at center: CGPoint, radius: CGFloat) -> CGRect {
            CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        }
    }
}

enum AnnotationCropHit {
    case outside
    case move
    case resize(SelectionEdge)
}

private enum LiveCaptureAction {
    case copy
    case download
    case ocr
}

@MainActor
final class AnnotationEditorController: NSObject,
    AnnotationCanvasViewDelegate,
    NSTextFieldDelegate
{
    private(set) var isPresenting = false

    private var backdropWindows: [AnnotationBackdropWindow] = []
    private var editorWindow: AnnotationEditorWindow?
    private weak var selectionOverlayController: SelectionOverlayController?
    private var toolbarPanel: AnnotationToolbarPanel?
    private var scrollView: NSScrollView?
    private var canvas: AnnotationCanvasView?
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var ocrButton: NSButton?
    private var downloadButton: NSButton?
    private var doneButton: NSButton?
    private var statusLabel: NSTextField?
    private var inlineTextField: NSTextField?
    private var inlineTextAnchor: CGPoint?
    private var inlineTextMaximumWidth: CGFloat = 0
    private var keyMonitor: Any?
    private var ocrTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var liveFinalizationTask: Task<Void, Never>?
    private var mosaicPreviewTask: Task<Void, Never>?
    private var allowsExpansion = false
    private var isLiveDesktopSession = false
    private var recapture: ((CGRect) async throws -> CGImage)?
    private var liveCapture: ((CGRect) async throws -> CGImage)?
    private var liveScreenFrame: CGRect?
    private var capturedRegion: CGRect?
    private var committedScreenSelection: CGRect?
    private var isExtendingSelection = false
    private weak var previouslyActiveApplication: NSRunningApplication?
    private var onComplete: ((CGImage) -> Void)?
    private var onTextCopied: (() -> Void)?
    private var onCancel: (() -> Void)?

    func present(
        image: CGImage,
        over region: CGRect,
        allowsExpansion: Bool = false,
        recapture: ((CGRect) async throws -> CGImage)? = nil,
        selectionOverlayController: SelectionOverlayController? = nil,
        onComplete: @escaping (CGImage) -> Void,
        onTextCopied: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard !isPresenting else {
            onCancel()
            return
        }
        guard !allowsExpansion || selectionOverlayController != nil else {
            onCancel()
            return
        }

        isPresenting = true
        self.onComplete = onComplete
        self.onTextCopied = onTextCopied
        self.onCancel = onCancel
        self.allowsExpansion = allowsExpansion
        self.recapture = recapture
        self.selectionOverlayController = selectionOverlayController
        capturedRegion = region
        committedScreenSelection = allowsExpansion ? region : nil
        let activeApplication = NSWorkspace.shared.frontmostApplication
        if activeApplication?.processIdentifier != NSRunningApplication.current.processIdentifier {
            previouslyActiveApplication = activeApplication
        }

        let canvasSize = AnnotationGeometry.canvasSize(
            imageSize: CGSize(width: image.width, height: image.height),
            viewportSize: region.size
        )
        let canvas = AnnotationCanvasView(
            image: image,
            frame: CGRect(origin: .zero, size: canvasSize),
            cropMode: allowsExpansion ? .screenManaged : .disabled
        )
        canvas.delegate = self
        self.canvas = canvas

        let window = AnnotationEditorWindow(contentRect: region)
        let scrollView = NSScrollView(
            frame: CGRect(origin: .zero, size: region.size)
        )
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = canvasSize.height > region.height + 0.5
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = canvas
        window.contentView = scrollView
        editorWindow = window
        self.scrollView = scrollView

        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        if !allowsExpansion {
            backdropWindows = NSScreen.screens.map { screen in
                AnnotationBackdropWindow(screen: screen)
            }
        }

        let toolbar = makeToolbar()
        toolbarPanel = toolbar
        positionToolbar(toolbar, below: region)
        setTool(nil)
        statusLabel?.stringValue = allowsExpansion
            ? ClipLocalization.text(
                "Drag to crop · Double-click to finish",
                "拖动边框裁剪 · 双击完成"
            )
            : ClipLocalization.text(
                "Annotate · Double-click to finish",
                "标注长图 · 双击完成"
            )
        installKeyMonitor()

        backdropWindows.forEach { $0.orderFrontRegardless() }
        window.orderFrontRegardless()
        if let selectionOverlayController, allowsExpansion {
            selectionOverlayController.beginAdjustment(
                selection: region,
                onPreview: { [weak self] selection in
                    self?.handleScreenSelectionPreview(selection)
                },
                onCommit: { [weak self] selection in
                    self?.handleScreenSelectionCommit(selection)
                },
                onComplete: { [weak self] selection in
                    self?.handleScreenSelectionCompletion(selection)
                }
            )
        }
        toolbar.alphaValue = 0
        toolbar.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        if !allowsExpansion {
            window.makeKey()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            toolbar.animator().alphaValue = 1
        }
    }

    /// Presents advanced static capture without replacing the desktop with a
    /// bitmap. The selection and annotations remain transparent overlays until
    /// an output action captures the final rectangle.
    func presentLive(
        over region: CGRect,
        capture: @escaping (CGRect) async throws -> CGImage,
        selectionOverlayController: SelectionOverlayController,
        onComplete: @escaping (CGImage) -> Void,
        onTextCopied: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard !isPresenting else {
            onCancel()
            return
        }

        let screenFrame = screenUnionFrame()
        guard !screenFrame.isNull, !screenFrame.isEmpty else {
            onCancel()
            return
        }

        isPresenting = true
        isLiveDesktopSession = true
        allowsExpansion = true
        self.liveCapture = capture
        liveScreenFrame = screenFrame
        self.selectionOverlayController = selectionOverlayController
        committedScreenSelection = region
        self.onComplete = onComplete
        self.onTextCopied = onTextCopied
        self.onCancel = onCancel

        let activeApplication = NSWorkspace.shared.frontmostApplication
        if activeApplication?.processIdentifier != NSRunningApplication.current.processIdentifier {
            previouslyActiveApplication = activeApplication
        }

        let canvas = AnnotationCanvasView(
            liveFrame: CGRect(origin: .zero, size: screenFrame.size)
        )
        canvas.delegate = self
        canvas.setInteractionRect(liveCanvasRect(for: region))
        self.canvas = canvas

        let window = AnnotationEditorWindow(
            contentRect: screenFrame,
            isTransparent: true
        )
        window.contentView = canvas
        editorWindow = window

        let toolbar = makeToolbar()
        toolbarPanel = toolbar
        positionToolbar(toolbar, below: region)
        setTool(nil)
        statusLabel?.stringValue = ClipLocalization.text(
            "Drag to crop · Double-click to finish",
            "拖动边框裁剪 · 双击完成"
        )
        installKeyMonitor()

        window.orderFrontRegardless()
        selectionOverlayController.beginAdjustment(
            selection: region,
            onPreview: { [weak self] selection in
                self?.handleScreenSelectionPreview(selection)
            },
            onCommit: { [weak self] selection in
                self?.handleScreenSelectionCommit(selection)
            },
            onComplete: { [weak self] selection in
                self?.handleScreenSelectionCompletion(selection)
            }
        )
        toolbar.alphaValue = 0
        toolbar.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            toolbar.animator().alphaValue = 1
        }
    }

    func cancel() {
        guard isPresenting else { return }
        let handler = onCancel
        dismiss()
        handler?()
    }

    func annotationCanvas(
        _ canvas: AnnotationCanvasView,
        requestedTextAt point: CGPoint
    ) {
        commitInlineText()

        let maximumWidth = max(1, min(360, canvas.bounds.width - 16))
        let width = min(160, maximumWidth)
        let x = min(
            max(point.x, 8),
            max(8, canvas.bounds.maxX - width - 8)
        )
        let y = min(
            max(point.y - 4, 8),
            max(8, canvas.bounds.maxY - 38)
        )

        let field = NSTextField(frame: CGRect(x: x, y: y, width: width, height: 30))
        field.placeholderString = ClipLocalization.text("Type a note", "输入文字")
        field.font = .systemFont(ofSize: 18, weight: .semibold)
        field.textColor = .systemRed
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.delegate = self
        field.target = self
        field.action = #selector(commitInlineTextFromAction)

        inlineTextField = field
        inlineTextAnchor = point
        inlineTextMaximumWidth = maximumWidth
        canvas.addSubview(field)
        editorWindow?.makeFirstResponder(field)
    }

    func annotationCanvasRequestedCompletion(_ canvas: AnnotationCanvasView) {
        complete()
    }

    func annotationCanvas(
        _ canvas: AnnotationCanvasView,
        didAdjustCropTo _: CGRect
    ) {
        // Canvas-owned crop editing is retained only for isolated logic tests.
        // App flows use either the screen-managed static selection or no crop.
    }

    func annotationCanvas(
        _ canvas: AnnotationCanvasView,
        didChangeCropPreviewTo rect: CGRect?
    ) {
        // Screen-managed selection never receives crop events from the canvas.
    }

    func annotationCanvas(
        _ canvas: AnnotationCanvasView,
        requestedCropExtensionTo rect: CGRect
    ) {
        // Screen-managed selection never receives crop events from the canvas.
    }

    private func handleScreenSelectionPreview(_ selection: CGRect) {
        guard isLiveDesktopSession else {
            // The view owns the live frame. Captured pixels are intentionally
            // left untouched until mouse-up in the legacy captured-image path.
            return
        }
        canvas?.setInteractionRect(liveCanvasRect(for: selection))
    }

    private func handleScreenSelectionCommit(_ selection: CGRect) {
        if isLiveDesktopSession {
            committedScreenSelection = selection
            canvas?.setInteractionRect(liveCanvasRect(for: selection))
            if let toolbarPanel {
                positionToolbar(toolbarPanel, below: selection)
                toolbarPanel.orderFrontRegardless()
            }
            showStatus(ClipLocalization.text("Selection adjusted", "选区已调整"))
            return
        }
        guard !isExtendingSelection,
              selection.width >= 8,
              selection.height >= 8,
              let capturedRegion else { return }

        if capturedRegion.insetBy(dx: -0.5, dy: -0.5).contains(selection) {
            commitScreenSelection(selection)
        } else {
            recaptureForScreenSelection(selection)
        }
    }

    private func handleScreenSelectionCompletion(_ selection: CGRect) {
        guard !isExtendingSelection else { return }
        if isLiveDesktopSession {
            committedScreenSelection = selection
            beginLiveCaptureAction(.copy)
            return
        }
        commitScreenSelection(selection)
        complete()
    }

    private func liveCanvasRect(for selection: CGRect) -> CGRect? {
        guard let liveScreenFrame else { return nil }
        let rect = CGRect(
            x: selection.minX - liveScreenFrame.minX,
            y: liveScreenFrame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        ).intersection(CGRect(origin: .zero, size: liveScreenFrame.size))
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    private func commitScreenSelection(_ selection: CGRect) {
        guard let capturedRegion,
              let canvas,
              let crop = canvasRect(
                  forScreenRect: selection,
                  capturedRegion: capturedRegion,
                  canvasBounds: canvas.bounds
              ) else { return }
        committedScreenSelection = selection
        canvas.setManagedCropRect(crop)
        if let toolbarPanel {
            positionToolbar(toolbarPanel, below: selection)
        }
        showStatus(ClipLocalization.text("Selection adjusted", "选区已调整"))
    }

    private func screenUnionFrame() -> CGRect {
        guard let first = NSScreen.screens.first else { return .null }
        return NSScreen.screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }

    private func recaptureForScreenSelection(_ selection: CGRect) {
        guard let recapture,
              let capturedRegion,
              !isExtendingSelection else { return }
        let expanded = capturedRegion.union(selection).intersection(screenUnionFrame())
        guard !expanded.isNull, expanded.width >= 8, expanded.height >= 8 else { return }

        commitInlineText()
        setRecaptureState(true)
        showStatus(
            ClipLocalization.text("Extending selection…", "正在扩展选区…"),
            hidesAutomatically: false
        )

        Task { [weak self] in
            do {
                let image = try await recapture(expanded)
                guard let self, self.isPresenting else { return }
                self.rebuildCanvas(
                    image: image,
                    expandedScreenRect: expanded,
                    selectionScreenRect: selection
                )
                self.committedScreenSelection = selection
                self.replaceScreenSelection(selection)
                self.showStatus(ClipLocalization.text("Selection extended", "选区已扩展"))
            } catch {
                guard let self, self.isPresenting else { return }
                if let committed = self.committedScreenSelection {
                    self.replaceScreenSelection(committed)
                }
                self.showStatus(
                    ClipLocalization.text("Could not extend selection", "无法扩展选区")
                )
            }
            self?.setRecaptureState(false)
        }
    }

    private func setRecaptureState(_ active: Bool) {
        isExtendingSelection = active
        if let selectionOverlayController {
            selectionOverlayController.setAdjustmentInteractionEnabled(!active)
        }
        doneButton?.isEnabled = !active
        ocrButton?.isEnabled = !active
        downloadButton?.isEnabled = !active
        toolButtons.values.forEach { $0.isEnabled = !active }
    }

    private func replaceScreenSelection(_ selection: CGRect) {
        if let selectionOverlayController {
            selectionOverlayController.replaceAdjustmentSelection(selection)
        }
    }

    private func canvasRect(
        forScreenRect selection: CGRect,
        capturedRegion: CGRect,
        canvasBounds: CGRect
    ) -> CGRect? {
        guard capturedRegion.width > 0,
              capturedRegion.height > 0,
              canvasBounds.width > 0,
              canvasBounds.height > 0 else { return nil }
        let scaleX = canvasBounds.width / capturedRegion.width
        let scaleY = canvasBounds.height / capturedRegion.height
        let rect = CGRect(
            x: (selection.minX - capturedRegion.minX) * scaleX,
            y: (capturedRegion.maxY - selection.maxY) * scaleY,
            width: selection.width * scaleX,
            height: selection.height * scaleY
        ).intersection(canvasBounds)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    /// Re-capturing replaces only the frozen image window. The full-screen
    /// selection surface stays visible and interactive throughout, so there is
    /// no chrome handoff to flash or become clipped.
    private func rebuildCanvas(
        image: CGImage,
        expandedScreenRect: CGRect,
        selectionScreenRect: CGRect
    ) {
        guard let oldCanvas = canvas,
              let editorWindow,
              let scrollView,
              let toolbarPanel else { return }
        let oldRegion = capturedRegion ?? editorWindow.frame
        let delta = CGPoint(
            x: oldRegion.minX - expandedScreenRect.minX,
            y: expandedScreenRect.maxY - oldRegion.maxY
        )
        let translatedDocument = oldCanvas.document.mappingElements {
            $0.translated(by: delta)
        }

        let canvasSize = AnnotationGeometry.canvasSize(
            imageSize: CGSize(width: image.width, height: image.height),
            viewportSize: expandedScreenRect.size
        )
        let newCanvas = AnnotationCanvasView(
            image: image,
            frame: CGRect(origin: .zero, size: canvasSize),
            cropMode: .screenManaged
        )
        newCanvas.delegate = self
        guard let cropRect = canvasRect(
            forScreenRect: selectionScreenRect,
            capturedRegion: expandedScreenRect,
            canvasBounds: newCanvas.bounds
        ) else { return }
        newCanvas.restore(
            document: translatedDocument,
            cropRect: cropRect
        )

        capturedRegion = expandedScreenRect
        editorWindow.setFrame(expandedScreenRect, display: false)
        scrollView.frame = CGRect(origin: .zero, size: expandedScreenRect.size)
        scrollView.hasVerticalScroller = canvasSize.height > expandedScreenRect.height + 0.5
        scrollView.documentView = newCanvas
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        canvas = newCanvas
        editorWindow.displayIfNeeded()
        if let selectionOverlayController {
            selectionOverlayController.bringAdjustmentSurfaceToFront()
        }
        positionToolbar(toolbarPanel, below: selectionScreenRect)
        toolbarPanel.orderFrontRegardless()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === inlineTextField,
              let canvas,
              let anchor = inlineTextAnchor else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: field.font ?? NSFont.systemFont(ofSize: 18, weight: .semibold)
        ]
        let measuredWidth = (field.stringValue as NSString)
            .size(withAttributes: attributes)
            .width
        let width = min(
            inlineTextMaximumWidth,
            max(min(120, inlineTextMaximumWidth), measuredWidth + 12)
        )
        var frame = field.frame
        frame.size.width = width
        frame.origin.x = min(
            max(anchor.x, 8),
            max(8, canvas.bounds.maxX - width - 8)
        )
        field.frame = frame
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let movement = notification.userInfo?["NSTextMovement"] as? Int else {
            commitInlineText()
            return
        }
        if movement == NSCancelTextMovement {
            discardInlineText()
        } else {
            commitInlineText()
        }
    }

    private func makeToolbar() -> AnnotationToolbarPanel {
        let panel = AnnotationToolbarPanel(
            contentRect: CGRect(x: 0, y: 0, width: 612, height: 54)
        )
        let effect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 15
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = effect

        let mosaic = makeToolButton(
            tool: .mosaic,
            symbol: "square.grid.3x3.fill",
            label: ClipLocalization.text("Mosaic brush", "马赛克画笔")
        )
        let text = makeToolButton(
            tool: .text,
            symbol: "textformat",
            label: ClipLocalization.text("Text note", "文字备注")
        )
        text.image = makeTextToolImage()
        let rectangle = makeToolButton(
            tool: .rectangle,
            symbol: "rectangle",
            label: ClipLocalization.text("Rectangle", "矩形标记")
        )
        let ellipse = makeToolButton(
            tool: .ellipse,
            symbol: "circle",
            label: ClipLocalization.text("Ellipse", "圆形标记")
        )
        let line = makeToolButton(
            tool: .line,
            symbol: "line.diagonal",
            label: ClipLocalization.text("Line", "无箭头连线")
        )
        let arrow = makeToolButton(
            tool: .arrow,
            symbol: "arrow.up.right",
            label: ClipLocalization.text("Arrow", "箭头连线")
        )
        let ocr = makeActionButton(
            symbol: "text.viewfinder",
            label: ClipLocalization.text("Recognize and copy text", "识别文字并复制"),
            action: #selector(runOCR)
        )
        ocrButton = ocr
        let download = makeActionButton(
            symbol: "arrow.down.to.line",
            label: ClipLocalization.text("Save to Downloads", "保存到下载"),
            action: #selector(downloadCapture)
        )
        downloadButton = download

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let undo = makeActionButton(
            symbol: "arrow.uturn.backward",
            label: ClipLocalization.text("Undo", "撤销"),
            action: #selector(undo)
        )
        let status = NSTextField(labelWithString: "")
        status.alignment = .center
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 128).isActive = true
        statusLabel = status

        let cancel = makeActionButton(
            symbol: "xmark",
            label: ClipLocalization.text("Cancel", "取消"),
            action: #selector(cancelFromToolbar)
        )
        let done = makeActionButton(
            symbol: "checkmark",
            label: ClipLocalization.text("Finish and copy capture", "完成并复制截图"),
            action: #selector(complete)
        )
        doneButton = done
        done.bezelStyle = .rounded
        done.controlSize = .large
        done.keyEquivalent = "\r"
        done.contentTintColor = .controlAccentColor

        let stack = NSStackView(views: [
            mosaic,
            text,
            rectangle,
            ellipse,
            line,
            arrow,
            ocr,
            download,
            divider,
            undo,
            status,
            cancel,
            done
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        ])
        return panel
    }

    private func makeToolButton(
        tool: AnnotationTool,
        symbol: String,
        label: String
    ) -> NSButton {
        let button = makeActionButton(
            symbol: symbol,
            label: label,
            action: #selector(selectTool(_:))
        )
        button.setButtonType(.toggle)
        button.tag = tool.rawValue
        toolButtons[tool] = button
        return button
    }

    private func makeActionButton(
        symbol: String,
        label: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .recessed
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = action
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 42).isActive = true
        button.heightAnchor.constraint(equalToConstant: 42).isActive = true
        button.setAccessibilityLabel(label)
        return button
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = AnnotationTool(rawValue: sender.tag) else { return }
        commitInlineText()
        setTool(sender.state == .on ? tool : nil)
        if isLiveDesktopSession, sender.state == .on, tool == .mosaic {
            prepareLiveMosaicPreview()
        }
    }

    private func setTool(_ tool: AnnotationTool?) {
        canvas?.setTool(tool)
        for (candidate, button) in toolButtons {
            button.state = candidate == tool ? .on : .off
            button.contentTintColor = candidate == tool ? .controlAccentColor : .labelColor
        }
        if allowsExpansion {
            let editsImage = tool != nil
            editorWindow?.ignoresMouseEvents = !editsImage
            if let selectionOverlayController {
                selectionOverlayController.setAdjustmentInteractionEnabled(!editsImage)
            }
            if editsImage {
                editorWindow?.orderFrontRegardless()
                toolbarPanel?.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                editorWindow?.makeKey()
            } else {
                if let selectionOverlayController {
                    selectionOverlayController.bringAdjustmentSurfaceToFront()
                }
                toolbarPanel?.orderFrontRegardless()
            }
        } else {
            editorWindow?.makeKey()
        }
    }

    private func makeTextToolImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let glyph = "T" as NSString
        let size = glyph.size(withAttributes: attributes)
        glyph.draw(
            at: NSPoint(
                x: (image.size.width - size.width) / 2,
                y: (image.size.height - size.height) / 2
            ),
            withAttributes: attributes
        )
        image.unlockFocus()
        image.isTemplate = true
        image.accessibilityDescription = ClipLocalization.text("Text note", "文字备注")
        return image
    }

    @objc private func undo() {
        commitInlineText()
        canvas?.undo()
        editorWindow?.makeKey()
    }

    @objc private func runOCR() {
        if isLiveDesktopSession {
            beginLiveCaptureAction(.ocr)
            return
        }
        guard ocrTask == nil, let canvas else { return }
        commitInlineText()
        guard let image = canvas.sourceImage() else { return }

        ocrButton?.isEnabled = false
        showStatus(ClipLocalization.text("Recognizing…", "识别中…"), hidesAutomatically: false)
        let sendableImage = SendableAnnotationImage(value: image)
        ocrTask = Task { [weak self] in
            do {
                let text = try await OCRTextRecognizer.recognize(sendableImage.value)
                try Task.checkCancellation()
                guard let self, self.isPresenting else { return }
                if text.isEmpty {
                    self.showStatus(ClipLocalization.text("No text found", "未识别到文字"))
                } else {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    if pasteboard.setString(text, forType: .string) {
                        let handler = self.onTextCopied
                        self.dismiss()
                        handler?()
                        return
                    } else {
                        self.showStatus(ClipLocalization.text("Copy failed", "复制失败"))
                    }
                }
            } catch is CancellationError {
                // Closing the editor cancels OCR without additional UI.
            } catch {
                self?.showStatus(ClipLocalization.text("Recognition failed", "无法识别"))
            }
            self?.ocrButton?.isEnabled = true
            self?.ocrTask = nil
        }
    }

    @objc private func downloadCapture() {
        if isLiveDesktopSession {
            beginLiveCaptureAction(.download)
            return
        }
        guard downloadTask == nil else { return }
        commitInlineText()
        guard let image = canvas?.renderedImage() else {
            showStatus(ClipLocalization.text("Could not save", "无法保存"))
            return
        }
        let pixelsPerPoint = CaptureImageResolution.pixelsPerPoint(
            pixelWidth: image.width,
            pointWidth: canvas?.bounds.width ?? CGFloat(image.width)
        )

        downloadButton?.isEnabled = false
        showStatus(ClipLocalization.text("Saving…", "保存中…"), hidesAutomatically: false)
        let sendableImage = SendableAnnotationImage(value: image)
        downloadTask = Task { [weak self] in
            do {
                _ = try await CaptureDownloadWriter.write(
                    sendableImage.value,
                    pixelsPerPoint: pixelsPerPoint
                )
                try Task.checkCancellation()
                guard let self, self.isPresenting else { return }
                self.showStatus(ClipLocalization.text("Saved to Downloads", "已保存到下载"))
            } catch is CancellationError {
                // Closing the editor cancels the download feedback.
            } catch {
                self?.showStatus(ClipLocalization.text("Could not save", "无法保存"))
            }
            self?.downloadButton?.isEnabled = true
            self?.downloadTask = nil
        }
    }

    @objc private func complete() {
        guard !isExtendingSelection else { return }
        if isLiveDesktopSession {
            beginLiveCaptureAction(.copy)
            return
        }
        commitInlineText()
        guard let image = canvas?.renderedImage() else {
            showStatus(ClipLocalization.text("Could not finish", "无法完成"))
            return
        }
        let handler = onComplete
        dismiss()
        handler?(image)
    }

    private func prepareLiveMosaicPreview() {
        guard mosaicPreviewTask == nil,
              let liveCapture,
              let selection = committedScreenSelection,
              let destination = liveCanvasRect(for: selection) else { return }
        mosaicPreviewTask = Task { [weak self] in
            defer { self?.mosaicPreviewTask = nil }
            do {
                let image = try await liveCapture(selection)
                try Task.checkCancellation()
                guard let self, self.isPresenting, self.isLiveDesktopSession else { return }
                self.canvas?.setLiveMosaicPreview(image, in: destination)
            } catch {
                guard let self, self.isPresenting else { return }
                self.showStatus(
                    ClipLocalization.text(
                        "Mosaic preview unavailable",
                        "马赛克预览不可用"
                    )
                )
            }
        }
    }

    private func beginLiveCaptureAction(_ action: LiveCaptureAction) {
        guard liveFinalizationTask == nil,
              let liveCapture,
              let committedSelection = committedScreenSelection else { return }
        let selection = ScreenCaptureGeometry.alignedToPointGrid(committedSelection)
        guard selection.width >= 8,
              selection.height >= 8 else { return }
        committedScreenSelection = selection
        commitInlineText()
        setLiveCaptureState(true)
        switch action {
        case .copy:
            showStatus(
                ClipLocalization.text("Capturing…", "正在截图…"),
                hidesAutomatically: false
            )
        case .download:
            showStatus(
                ClipLocalization.text("Saving…", "保存中…"),
                hidesAutomatically: false
            )
        case .ocr:
            showStatus(
                ClipLocalization.text("Recognizing…", "识别中…"),
                hidesAutomatically: false
            )
        }

        liveFinalizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await liveCapture(selection)
                try Task.checkCancellation()
                guard self.isPresenting else { return }

                switch action {
                case .copy:
                    guard let image = self.renderLiveCapture(
                        source,
                        selection: selection
                    ) else { throw ClipError.captureFailed }
                    let handler = self.onComplete
                    self.dismiss()
                    handler?(image)
                case .download:
                    guard let image = self.renderLiveCapture(
                        source,
                        selection: selection
                    ) else { throw ClipError.captureFailed }
                    _ = try await CaptureDownloadWriter.write(
                        image,
                        pixelsPerPoint: CaptureImageResolution.pixelsPerPoint(
                            pixelWidth: image.width,
                            pointWidth: selection.width
                        )
                    )
                    try Task.checkCancellation()
                    guard self.isPresenting else { return }
                    self.showStatus(
                        ClipLocalization.text("Saved to Downloads", "已保存到下载")
                    )
                    self.setLiveCaptureState(false)
                case .ocr:
                    let text = try await OCRTextRecognizer.recognize(source)
                    try Task.checkCancellation()
                    guard self.isPresenting else { return }
                    if text.isEmpty {
                        self.showStatus(ClipLocalization.text("No text found", "未识别到文字"))
                        self.setLiveCaptureState(false)
                    } else {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        guard pasteboard.setString(text, forType: .string) else {
                            throw ClipError.captureFailed
                        }
                        let handler = self.onTextCopied
                        self.dismiss()
                        handler?()
                    }
                }
            } catch is CancellationError {
                // Closing the editor cancels the in-flight output action.
            } catch {
                guard self.isPresenting else { return }
                let message: String
                switch action {
                case .copy:
                    message = ClipLocalization.text("Could not finish", "无法完成")
                case .download:
                    message = ClipLocalization.text("Could not save", "无法保存")
                case .ocr:
                    message = ClipLocalization.text("Recognition failed", "无法识别")
                }
                self.showStatus(message)
                self.setLiveCaptureState(false)
            }
            self.liveFinalizationTask = nil
        }
    }

    private func renderLiveCapture(
        _ image: CGImage,
        selection: CGRect
    ) -> CGImage? {
        guard let canvas else { return image }
        guard !canvas.document.elements.isEmpty else { return image }
        guard let selectionInCanvas = liveCanvasRect(for: selection) else { return nil }
        let translated = canvas.document.mappingElements {
            $0.translated(by: CGPoint(
                x: -selectionInCanvas.minX,
                y: -selectionInCanvas.minY
            ))
        }
        let renderer = AnnotationCanvasView(
            image: image,
            frame: CGRect(origin: .zero, size: selection.size),
            cropMode: .disabled
        )
        renderer.setDocument(translated)
        return renderer.renderedImage()
    }

    private func setLiveCaptureState(_ active: Bool) {
        selectionOverlayController?.setAdjustmentInteractionEnabled(!active)
        doneButton?.isEnabled = !active
        ocrButton?.isEnabled = !active
        downloadButton?.isEnabled = !active
        toolButtons.values.forEach { $0.isEnabled = !active }
    }

    @objc private func cancelFromToolbar() {
        cancel()
    }

    @objc private func commitInlineTextFromAction() {
        commitInlineText()
    }

    private func commitInlineText() {
        guard let field = inlineTextField else { return }
        let text = field.stringValue
        let origin = CGPoint(
            x: field.frame.minX + 2,
            y: field.frame.minY + 4
        )
        field.removeFromSuperview()
        inlineTextField = nil
        inlineTextAnchor = nil
        inlineTextMaximumWidth = 0
        canvas?.appendText(text, at: origin)
        setTool(nil)
    }

    private func discardInlineText() {
        inlineTextField?.removeFromSuperview()
        inlineTextField = nil
        inlineTextAnchor = nil
        inlineTextMaximumWidth = 0
        setTool(nil)
    }

    private func showStatus(
        _ text: String,
        hidesAutomatically: Bool = true
    ) {
        statusTask?.cancel()
        statusLabel?.alphaValue = 1
        statusLabel?.stringValue = text
        guard hidesAutomatically else { return }
        statusTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_400_000_000)
            } catch {
                return
            }
            guard let self, self.isPresenting else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                self.statusLabel?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.statusLabel?.stringValue = ""
                    self?.statusLabel?.alphaValue = 1
                }
            })
        }
    }

    private func positionToolbar(
        _ toolbar: NSWindow,
        below region: CGRect
    ) {
        let screen = NSScreen.screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(region).area
                < rhs.visibleFrame.intersection(region).area
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }

        let x = min(
            max(region.midX - toolbar.frame.width / 2, visibleFrame.minX + 8),
            visibleFrame.maxX - toolbar.frame.width - 8
        )
        let below = region.minY - toolbar.frame.height - 8
        let above = region.maxY + 8
        let y = below >= visibleFrame.minY + 8
            ? below
            : min(above, visibleFrame.maxY - toolbar.frame.height - 8)
        toolbar.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                if self.inlineTextField != nil {
                    self.discardInlineText()
                } else {
                    self.cancel()
                }
                return nil
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "z" {
                self.undo()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func dismiss() {
        guard isPresenting else { return }
        isPresenting = false
        removeKeyMonitor()
        ocrTask?.cancel()
        ocrTask = nil
        downloadTask?.cancel()
        downloadTask = nil
        liveFinalizationTask?.cancel()
        liveFinalizationTask = nil
        mosaicPreviewTask?.cancel()
        mosaicPreviewTask = nil
        statusTask?.cancel()
        statusTask = nil
        discardInlineText()

        editorWindow?.orderOut(nil)
        backdropWindows.forEach { $0.orderOut(nil) }
        if let toolbarPanel {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                toolbarPanel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    toolbarPanel.orderOut(nil)
                }
            })
        }

        backdropWindows.removeAll()
        editorWindow = nil
        selectionOverlayController = nil
        toolbarPanel = nil
        scrollView = nil
        canvas = nil
        toolButtons = [:]
        ocrButton = nil
        downloadButton = nil
        doneButton = nil
        statusLabel = nil
        allowsExpansion = false
        isLiveDesktopSession = false
        recapture = nil
        liveCapture = nil
        liveScreenFrame = nil
        capturedRegion = nil
        committedScreenSelection = nil
        isExtendingSelection = false
        onComplete = nil
        onTextCopied = nil
        onCancel = nil
        previouslyActiveApplication?.activate()
        previouslyActiveApplication = nil
    }
}

private final class AnnotationBackdropWindow: NSWindow {
    convenience init(screen: NSScreen) {
        self.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.38)
        hasShadow = false
        sharingType = .readOnly
        level = AnnotationOverlayWindowLevel.selection
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
    }
}

private final class AnnotationEditorWindow: NSPanel {
    init(contentRect: CGRect, isTransparent: Bool = false) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = !isTransparent
        backgroundColor = isTransparent ? .clear : .black
        hasShadow = false
        sharingType = .readOnly
        level = AnnotationOverlayWindowLevel.selection
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AnnotationToolbarPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .readOnly
        level = AnnotationOverlayWindowLevel.toolbar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum OCRTextRecognizer {
    static func recognize(_ image: CGImage) async throws -> String {
        let sendableImage = SendableAnnotationImage(value: image)
        let preferredLanguages = ClipLanguagePreferences.language == .simplifiedChinese
            ? ["zh-Hans", "zh-Hant", "en-US"]
            : ["en-US", "zh-Hans", "zh-Hant"]
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let supportedLanguages = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = preferredLanguages.filter {
                supportedLanguages.contains($0)
            }
            // Large Retina selections can contain small but readable text.
            // Avoid filtering those lines before Vision has a chance to score them.
            request.minimumTextHeight = 0

            let handler = VNImageRequestHandler(
                cgImage: sendableImage.value,
                orientation: .up,
                options: [:]
            )
            try handler.perform([request])
            let observations = (request.results ?? []).sorted { lhs, rhs in
                let verticalDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
                if verticalDistance > 0.018 {
                    return lhs.boundingBox.maxY > rhs.boundingBox.maxY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return observations.compactMap {
                $0.topCandidates(1).first?.string
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        }.value
    }
}

enum CaptureDownloadWriter {
    static func write(
        _ image: CGImage,
        pixelsPerPoint: CGFloat = 1,
        to directory: URL? = nil,
        date: Date = Date()
    ) async throws -> URL {
        let sendableImage = SendableAnnotationImage(value: image)
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let destinationDirectory = try directory ?? downloadsDirectory()
            let outputURL = availableURL(in: destinationDirectory, date: date)

            let data: Data
            do {
                data = try PNGImageEncoder.encode(
                    sendableImage.value,
                    pixelsPerPoint: pixelsPerPoint
                )
            } catch {
                throw CaptureDownloadError.pngEncodingFailed
            }
            try data.write(to: outputURL, options: .atomic)
            return outputURL
        }.value
    }

    private static func downloadsDirectory() throws -> URL {
        guard let url = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private static func availableURL(in directory: URL, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let baseName = "Clip \(formatter.string(from: date))"

        var suffix = 1
        while true {
            let name = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            let candidate = directory
                .appendingPathComponent(name)
                .appendingPathExtension("png")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}

private enum CaptureDownloadError: Error {
    case pngEncodingFailed
}

private struct SendableAnnotationImage: @unchecked Sendable {
    let value: CGImage
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return width * height
    }
}
