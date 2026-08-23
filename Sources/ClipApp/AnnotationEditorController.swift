import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
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
}

enum AnnotationEditorResult {
    case image(CGImage)
    case ocrTextCopied
}

@MainActor
protocol AnnotationCanvasViewDelegate: AnyObject {
    func annotationCanvas(_ canvas: AnnotationCanvasView, requestedTextAt point: CGPoint)
}

@MainActor
final class AnnotationCanvasView: NSView {
    weak var delegate: AnnotationCanvasViewDelegate?

    private(set) var document = AnnotationDocument()
    private(set) var tool: AnnotationTool?

    private let baseImage: CGImage
    private let baseNSImage: NSImage
    private lazy var pixelatedNSImage = makePixelatedImage()

    private var workingMosaicPoints: [CGPoint] = []
    private var workingShapeStart: CGPoint?
    private var workingShapeEnd: CGPoint?
    private var workingLineStart: CGPoint?
    private var workingLineEnd: CGPoint?

    init(image: CGImage, frame: CGRect) {
        baseImage = image
        baseNSImage = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
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

    func renderedImage() -> CGImage? {
        layoutSubtreeIfNeeded()
        guard bounds.width > 0,
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
        cacheDisplay(in: bounds, to: representation)
        return representation.cgImage
    }

    func sourceImage() -> CGImage {
        baseImage
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch tool {
        case .text?:
            cursor = .iBeam
        case .mosaic?, .rectangle?, .ellipse?, .line?, .arrow?:
            cursor = .crosshair
        case nil:
            cursor = .arrow
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = localPoint(for: event)
        guard bounds.contains(point) else { return }

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
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamped(localPoint(for: event))
        switch tool {
        case .mosaic?:
            guard !workingMosaicPoints.isEmpty else { return }
            if let previous = workingMosaicPoints.last,
               hypot(point.x - previous.x, point.y - previous.y) < 1.5 {
                return
            }
            workingMosaicPoints.append(point)
            needsDisplay = true
        case .rectangle?, .ellipse?:
            guard workingShapeStart != nil else { return }
            workingShapeEnd = point
            needsDisplay = true
        case .line?, .arrow?:
            guard workingLineStart != nil else { return }
            workingLineEnd = point
            needsDisplay = true
        case .text?, nil:
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
        case .text?, nil:
            break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSGraphicsContext.current?.imageInterpolation = .high
        baseNSImage.draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )

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
        guard let pixelatedNSImage,
              let context = NSGraphicsContext.current?.cgContext,
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
        pixelatedNSImage.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
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
        needsDisplay = true
    }

    private func localPoint(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}

@MainActor
final class AnnotationEditorController: NSObject,
    AnnotationCanvasViewDelegate,
    NSTextFieldDelegate
{
    private(set) var isPresenting = false

    private var backdropWindows: [AnnotationBackdropWindow] = []
    private var editorWindow: AnnotationEditorWindow?
    private var toolbarPanel: AnnotationToolbarPanel?
    private var canvas: AnnotationCanvasView?
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var ocrButton: NSButton?
    private var downloadButton: NSButton?
    private var statusLabel: NSTextField?
    private var inlineTextField: NSTextField?
    private var inlineTextAnchor: CGPoint?
    private var inlineTextMaximumWidth: CGFloat = 0
    private var keyMonitor: Any?
    private var ocrTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private weak var previouslyActiveApplication: NSRunningApplication?
    private var onComplete: ((CGImage) -> Void)?
    private var onTextCopied: (() -> Void)?
    private var onCancel: (() -> Void)?

    func present(
        image: CGImage,
        over region: CGRect,
        onComplete: @escaping (CGImage) -> Void,
        onTextCopied: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard !isPresenting else {
            onCancel()
            return
        }

        isPresenting = true
        self.onComplete = onComplete
        self.onTextCopied = onTextCopied
        self.onCancel = onCancel
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
            frame: CGRect(origin: .zero, size: canvasSize)
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

        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        backdropWindows = NSScreen.screens.map { screen in
            AnnotationBackdropWindow(screen: screen)
        }

        let toolbar = makeToolbar()
        toolbarPanel = toolbar
        positionToolbar(toolbar, below: region)
        setTool(nil)
        installKeyMonitor()

        backdropWindows.forEach { $0.orderFrontRegardless() }
        window.orderFrontRegardless()
        toolbar.alphaValue = 0
        toolbar.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
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
        field.placeholderString = "输入文字"
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
            label: "马赛克画笔"
        )
        let text = makeToolButton(
            tool: .text,
            symbol: "textformat",
            label: "文字备注"
        )
        text.image = makeTextToolImage()
        let rectangle = makeToolButton(
            tool: .rectangle,
            symbol: "rectangle",
            label: "矩形标记"
        )
        let ellipse = makeToolButton(
            tool: .ellipse,
            symbol: "circle",
            label: "圆形标记"
        )
        let line = makeToolButton(
            tool: .line,
            symbol: "line.diagonal",
            label: "无箭头连线"
        )
        let arrow = makeToolButton(
            tool: .arrow,
            symbol: "arrow.up.right",
            label: "箭头连线"
        )
        let ocr = makeActionButton(
            symbol: "text.viewfinder",
            label: "识别文字并复制",
            action: #selector(runOCR)
        )
        ocrButton = ocr
        let download = makeActionButton(
            symbol: "arrow.down.to.line",
            label: "保存到下载",
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
            label: "撤销",
            action: #selector(undo)
        )
        let status = NSTextField(labelWithString: "")
        status.alignment = .center
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 78).isActive = true
        statusLabel = status

        let cancel = makeActionButton(
            symbol: "xmark",
            label: "取消",
            action: #selector(cancelFromToolbar)
        )
        let done = makeActionButton(
            symbol: "checkmark",
            label: "完成并复制截图",
            action: #selector(complete)
        )
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
        setTool(tool)
    }

    private func setTool(_ tool: AnnotationTool?) {
        canvas?.setTool(tool)
        for (candidate, button) in toolButtons {
            button.state = candidate == tool ? .on : .off
            button.contentTintColor = candidate == tool ? .controlAccentColor : .labelColor
        }
        editorWindow?.makeKey()
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
        image.accessibilityDescription = "文字备注"
        return image
    }

    @objc private func undo() {
        commitInlineText()
        canvas?.undo()
        editorWindow?.makeKey()
    }

    @objc private func runOCR() {
        guard ocrTask == nil, let canvas else { return }
        commitInlineText()
        let image = canvas.sourceImage()

        ocrButton?.isEnabled = false
        showStatus("识别中…", hidesAutomatically: false)
        let sendableImage = SendableAnnotationImage(value: image)
        ocrTask = Task { [weak self] in
            do {
                let text = try await OCRTextRecognizer.recognize(sendableImage.value)
                try Task.checkCancellation()
                guard let self, self.isPresenting else { return }
                if text.isEmpty {
                    self.showStatus("未识别到文字")
                } else {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    if pasteboard.setString(text, forType: .string) {
                        let handler = self.onTextCopied
                        self.dismiss()
                        handler?()
                        return
                    } else {
                        self.showStatus("复制失败")
                    }
                }
            } catch is CancellationError {
                // Closing the editor cancels OCR without additional UI.
            } catch {
                self?.showStatus("无法识别")
            }
            self?.ocrButton?.isEnabled = true
            self?.ocrTask = nil
        }
    }

    @objc private func downloadCapture() {
        guard downloadTask == nil else { return }
        commitInlineText()
        guard let image = canvas?.renderedImage() else {
            showStatus("无法保存")
            return
        }

        downloadButton?.isEnabled = false
        showStatus("保存中…", hidesAutomatically: false)
        let sendableImage = SendableAnnotationImage(value: image)
        downloadTask = Task { [weak self] in
            do {
                _ = try await CaptureDownloadWriter.write(sendableImage.value)
                try Task.checkCancellation()
                guard let self, self.isPresenting else { return }
                self.showStatus("已保存到下载")
            } catch is CancellationError {
                // Closing the editor cancels the download feedback.
            } catch {
                self?.showStatus("无法保存")
            }
            self?.downloadButton?.isEnabled = true
            self?.downloadTask = nil
        }
    }

    @objc private func complete() {
        commitInlineText()
        guard let image = canvas?.renderedImage() else {
            showStatus("无法完成")
            return
        }
        let handler = onComplete
        dismiss()
        handler?(image)
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
        toolbarPanel = nil
        canvas = nil
        toolButtons = [:]
        ocrButton = nil
        downloadButton = nil
        statusLabel = nil
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
        sharingType = .none
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
    }
}

private final class AnnotationEditorWindow: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        sharingType = .none
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class AnnotationToolbarPanel: NSPanel {
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
        sharingType = .none
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum OCRTextRecognizer {
    static func recognize(_ image: CGImage) async throws -> String {
        let sendableImage = SendableAnnotationImage(value: image)
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US"]
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
        to directory: URL? = nil,
        date: Date = Date()
    ) async throws -> URL {
        let sendableImage = SendableAnnotationImage(value: image)
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let destinationDirectory = try directory ?? downloadsDirectory()
            let outputURL = availableURL(in: destinationDirectory, date: date)

            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                throw CaptureDownloadError.pngEncodingFailed
            }
            CGImageDestinationAddImage(destination, sendableImage.value, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw CaptureDownloadError.pngEncodingFailed
            }
            try (data as Data).write(to: outputURL, options: .atomic)
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
