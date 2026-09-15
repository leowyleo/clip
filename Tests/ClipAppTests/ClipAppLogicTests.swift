import AppKit
import Carbon.HIToolbox
import ClipCore
import Testing
@testable import ClipApp

@Suite("Clip app shell logic", .serialized)
struct ClipAppLogicTests {
    @Test("Selection border and grid use one identical adaptive stroke")
    func selectionChromeUsesOneConsistentStroke() {
        #expect(SelectionOverlayChromeStyle.lineWidth == 1)
        #expect(SelectionOverlayChromeStyle.lineDashPattern == [3, 2])
        #expect(SelectionOverlayChromeStyle.darkStrokeOpacity == 0.093)
        #expect(SelectionOverlayChromeStyle.lightStrokeOpacity == 0.137)
        let darkReference = SelectionOverlayChromeStyle.referenceGray(over: 32.0 / 255.0)
        let lightReference = SelectionOverlayChromeStyle.referenceGray(over: 253.0 / 255.0)
        #expect(abs(darkReference - 60.0 / 255.0) < 1.0 / 255.0)
        #expect(abs(lightReference - 233.0 / 255.0) < 1.0 / 255.0)
        #expect(SelectionOverlayChromeStyle.handleDiameter == 8)
    }

    @Test("Annotation toolbar remains above the interactive selection surface")
    @MainActor
    func annotationToolbarStaysClickableAfterSelectionAdjustment() {
        let toolbar = AnnotationToolbarPanel(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 54)
        )
        #expect(
            toolbar.level.rawValue
                > AnnotationOverlayWindowLevel.selection.rawValue
        )
    }

    @Test("Capture experience defaults to minimal and persists advanced")
    func captureExperiencePreferenceIsExplicitAndStable() {
        let suiteName = "ClipAppLogicTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(CaptureExperiencePreferences.mode(in: defaults) == .minimal)
        CaptureExperiencePreferences.setMode(.advanced, in: defaults)
        #expect(CaptureExperiencePreferences.mode(in: defaults) == .advanced)

        defaults.set("future-mode", forKey: CaptureExperiencePreferences.modeKey)
        #expect(CaptureExperiencePreferences.mode(in: defaults) == .minimal)
    }

    @Test("Advanced editing applies to region and scrolling captures")
    func advancedEditingAppliesToBothCaptureModes() {
        let suiteName = "ClipAppLogicTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!CaptureExperiencePreferences.usesEditor(for: .region, in: defaults))
        #expect(!CaptureExperiencePreferences.usesEditor(for: .scrolling, in: defaults))

        CaptureExperiencePreferences.setMode(.advanced, in: defaults)
        #expect(CaptureExperiencePreferences.usesEditor(for: .region, in: defaults))
        #expect(CaptureExperiencePreferences.usesEditor(for: .scrolling, in: defaults))
    }

    @Test("Long captures keep their aspect ratio inside the editor viewport")
    func longCaptureUsesScrollableCanvas() {
        let size = AnnotationGeometry.canvasSize(
            imageSize: CGSize(width: 1_600, height: 12_000),
            viewportSize: CGSize(width: 800, height: 600)
        )

        #expect(size == CGSize(width: 800, height: 6_000))
    }

    @Test("Second drag maps the flipped canvas selection to image pixels")
    func cropRectangleMapsToImagePixels() {
        let pixelRect = AnnotationGeometry.pixelCropRect(
            for: CGRect(x: 20, y: 10, width: 100, height: 40),
            canvasSize: CGSize(width: 200, height: 100),
            imageSize: CGSize(width: 400, height: 200)
        )

        #expect(pixelRect == CGRect(x: 40, y: 100, width: 200, height: 80))
    }

    @Test("Crop frame handles resize and move within the canvas")
    func cropFrameHandlesStayInsideCanvas() {
        let canvasBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let original = CGRect(x: 80, y: 60, width: 180, height: 120)

        #expect(
            SelectionEdge.topLeft.resizedRect(
                original: original,
                to: CGPoint(x: 40, y: 30),
                flipped: true,
                bounds: canvasBounds
            ) == CGRect(x: 40, y: 30, width: 220, height: 150)
        )
        #expect(
            AnnotationGeometry.movedCropRect(
                original: original,
                by: CGSize(width: 400, height: -100),
                within: canvasBounds
            ) == CGRect(x: 220, y: 0, width: 180, height: 120)
        )
        #expect(
            AnnotationGeometry.movedCropRect(
                original: original,
                by: CGSize(width: -120, height: 260)
            ) == CGRect(x: -40, y: 320, width: 180, height: 120)
        )
    }

    @Test("Crop frames may expand past the captured image in region mode")
    func cropFrameCanExpandBeyondCanvas() {
        let original = CGRect(x: 10, y: 10, width: 100, height: 80)

        let expanded = SelectionEdge.topLeft.resizedRect(
            original: original,
            to: CGPoint(x: -30, y: -20),
            flipped: true,
            bounds: nil
        )
        #expect(expanded == CGRect(x: -30, y: -20, width: 140, height: 110))

        // The same drag stays inside the canvas when expansion is unavailable,
        // which is the scrolling-capture behavior.
        let clamped = SelectionEdge.topLeft.resizedRect(
            original: original,
            to: CGPoint(x: -30, y: -20),
            flipped: true,
            bounds: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        #expect(clamped == CGRect(x: 0, y: 0, width: 110, height: 90))
    }

    @Test("Overlay edges resize the matching side in screen coordinates")
    func overlayEdgeResizeKeepsOppositeSideAnchored() {
        // AppKit coordinates: the rect's top edge sits at y = 200.
        let original = CGRect(x: 100, y: 100, width: 200, height: 100)

        let raised = SelectionEdge.top.resizedRect(
            original: original,
            to: CGPoint(x: 150, y: 260),
            flipped: false,
            bounds: nil
        )
        #expect(raised == CGRect(x: 100, y: 100, width: 200, height: 160))

        let narrowed = SelectionEdge.left.resizedRect(
            original: original,
            to: CGPoint(x: 60, y: 150),
            flipped: false,
            bounds: nil
        )
        #expect(narrowed == CGRect(x: 60, y: 100, width: 240, height: 100))
    }

    @Test("Zone hit testing prefers corners and reports visual edges")
    func zoneHitTestPrefersCornersAndEdges() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)

        #expect(
            SelectionEdge.zone(at: CGPoint(x: 2, y: 2), in: rect, padding: 10, flipped: false)
                == .bottomLeft
        )
        #expect(
            SelectionEdge.zone(at: CGPoint(x: 100, y: 3), in: rect, padding: 10, flipped: false)
                == .bottom
        )
        #expect(
            SelectionEdge.zone(at: CGPoint(x: 198, y: 97), in: rect, padding: 10, flipped: false)
                == .topRight
        )
        #expect(
            SelectionEdge.zone(at: CGPoint(x: 100, y: 50), in: rect, padding: 10, flipped: false)
                == nil
        )
        // Flipped coordinates put the visual bottom edge at rect.maxY.
        #expect(
            SelectionEdge.zone(at: CGPoint(x: 100, y: 97), in: rect, padding: 10, flipped: true)
                == .bottom
        )
    }

    @Test("Extending the crop translates annotations into the new canvas space")
    func cropExtensionTranslatesAnnotations() {
        var document = AnnotationDocument()
        document.append(.text(TextAnnotation(
            text: "note",
            origin: CGPoint(x: 10, y: 20)
        )))

        let translated = document.mappingElements {
            $0.translated(by: CGPoint(x: 30, y: 40))
        }

        #expect(translated.elements == [
            .text(TextAnnotation(text: "note", origin: CGPoint(x: 40, y: 60)))
        ])
    }

    @Test("Crop drag pipeline commits the adjusted frame live")
    @MainActor
    func cropDragCommitsAdjustedFrame() {
        let base = makeSolidColorImage(width: 400, height: 300, color: NSColor.white)
        let canvas = AnnotationCanvasView(
            image: base,
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas

        func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: 1
            )!
        }

        // Grab the right-edge dot mid-height and pull it 100pt to the left.
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 396, y: 150), clickCount: 1))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 350, y: 150), clickCount: 1))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 300, y: 150), clickCount: 1))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 300, y: 150), clickCount: 1))

        #expect(canvas.cropRect == CGRect(x: 0, y: 0, width: 300, height: 300))
    }

    @Test("Clicking outside the crop keeps the committed frame")
    @MainActor
    func outsideCropClickDoesNotStartANewCrop() {
        let base = makeSolidColorImage(width: 400, height: 300, color: NSColor.white)
        let canvas = AnnotationCanvasView(
            image: base,
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas

        func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
        }

        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 396, y: 150)))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 300, y: 150)))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 300, y: 150)))

        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 350, y: 150)))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 350, y: 150)))

        #expect(canvas.cropRect == CGRect(x: 0, y: 0, width: 300, height: 300))
    }

    @Test("Screen selection stays editable after an outside click")
    func screenSelectionSurvivesOutsideClick() {
        var state = AnnotationScreenSelectionState(
            selection: CGRect(x: 100, y: 100, width: 300, height: 200),
            screenBounds: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        let outsideStarted = state.beginDrag(at: CGPoint(x: 50, y: 50))
        #expect(!outsideStarted)
        #expect(state.selection == CGRect(x: 100, y: 100, width: 300, height: 200))

        let resizeStarted = state.beginDrag(at: CGPoint(x: 400, y: 200))
        let resized = state.updateDrag(to: CGPoint(x: 480, y: 200))
        #expect(resizeStarted)
        #expect(resized ==
            CGRect(x: 100, y: 100, width: 380, height: 200))
        let committed = state.endDrag()
        #expect(committed == CGRect(x: 100, y: 100, width: 380, height: 200))
    }

    @Test("Screen selection expansion updates before mouse-up")
    func screenSelectionExpansionIsLive() {
        var state = AnnotationScreenSelectionState(
            selection: CGRect(x: 200, y: 200, width: 300, height: 200),
            screenBounds: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        let resizeStarted = state.beginDrag(at: CGPoint(x: 200, y: 300))
        let resized = state.updateDrag(to: CGPoint(x: 120, y: 300))
        #expect(resizeStarted)
        #expect(resized ==
            CGRect(x: 120, y: 200, width: 380, height: 200))
        #expect(state.selection == CGRect(x: 120, y: 200, width: 380, height: 200))
    }

    @Test("Scrolling editor has no secondary crop controls")
    func scrollingEditorDisablesCropControls() {
        #expect(AnnotationCanvasCropMode.screenManaged.showsSelectionControls)
        #expect(!AnnotationCanvasCropMode.disabled.showsSelectionControls)
        #expect(!AnnotationCanvasCropMode.disabled.cropsRenderedOutput)
    }

    @Test("Static selection keeps a four-by-four grid through adjustment")
    func staticSelectionGridRemainsContinuous() {
        #expect(SelectionOverlayGuidePolicy.fractions == [0.25, 0.5, 0.75])
        #expect(
            SelectionOverlayGuidePolicy.showsGuides(
                displayMode: .selecting,
                selectionIsLocked: false,
                keepsDimWhilePassive: true
            )
        )
        #expect(
            SelectionOverlayGuidePolicy.showsGuides(
                displayMode: .selecting,
                selectionIsLocked: true,
                keepsDimWhilePassive: true
            )
        )
        #expect(
            SelectionOverlayGuidePolicy.showsGuides(
                displayMode: .passiveFrame,
                selectionIsLocked: true,
                keepsDimWhilePassive: true
            )
        )
        #expect(
            SelectionOverlayGuidePolicy.showsGuides(
                displayMode: .adjusting,
                selectionIsLocked: false,
                keepsDimWhilePassive: true
            )
        )
    }

    @Test("Scrolling selection removes grid and handles after mouse-up")
    func scrollingSelectionChromeStopsAtCommit() {
        #expect(
            SelectionOverlayDimPolicy.opacity(
                displayMode: .passiveFrame,
                keepsDimWhilePassive: false
            ) == 0.12
        )
        #expect(
            !SelectionOverlayGuidePolicy.showsGuides(
                displayMode: .selecting,
                selectionIsLocked: true,
                keepsDimWhilePassive: false
            )
        )
        #expect(
            !SelectionOverlayGuidePolicy.showsHandles(
                displayMode: .passiveFrame,
                selectionIsLocked: true,
                keepsDimWhilePassive: false
            )
        )
    }

    @Test("Region adjustment keeps its existing forty-percent mask")
    func regionAdjustmentMaskDoesNotChangeWithScrollingFix() {
        #expect(
            SelectionOverlayDimPolicy.opacity(
                displayMode: .adjusting,
                keepsDimWhilePassive: true
            ) == 0.40
        )
        #expect(
            SelectionOverlayGuidePolicy.showsGuides(
                displayMode: .adjusting,
                selectionIsLocked: false,
                keepsDimWhilePassive: true
            )
        )
        #expect(
            SelectionOverlayGuidePolicy.showsHandles(
                displayMode: .adjusting,
                selectionIsLocked: false,
                keepsDimWhilePassive: true
            )
        )
    }

    @Test("Editor output renders annotations over the layer-backed image")
    @MainActor
    func renderedOutputKeepsImageAndAnnotations() {
        let base = makeSolidColorImage(
            width: 100,
            height: 100,
            color: NSColor.white
        )
        let canvas = AnnotationCanvasView(
            image: base,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        canvas.appendText("A", at: CGPoint(x: 30, y: 40))

        let output = canvas.renderedImage()
        #expect(output != nil)
        guard let output else { return }
        #expect(output.width == base.width)
        #expect(output.height == base.height)

        let outputPixels = NSBitmapImageRep(cgImage: output)
        let basePixels = NSBitmapImageRep(cgImage: base)
        // The base image must survive the layer-backed render path.
        #expect(outputPixels.colorAt(x: 0, y: 0) == basePixels.colorAt(x: 0, y: 0))
        // The red annotation must be composited on top of it.
        var foundAnnotationPixel = false
        for y in stride(from: 0, to: output.height, by: 2) {
            for x in stride(from: 0, to: output.width, by: 2) {
                if let color = outputPixels.colorAt(x: x, y: y),
                   color != basePixels.colorAt(x: x, y: y) {
                    foundAnnotationPixel = true
                }
            }
        }
        #expect(foundAnnotationPixel)
    }

    @Test("Live desktop canvas records annotations only inside the selection")
    @MainActor
    func liveDesktopCanvasUsesTheSelectionAsItsInteractionBounds() throws {
        let canvas = AnnotationCanvasView(
            liveFrame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        canvas.setInteractionRect(CGRect(x: 100, y: 80, width: 200, height: 140))
        canvas.setTool(.rectangle)

        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
        }

        // Outside gestures are ignored.
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 20, y: 20)))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 60, y: 60)))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 60, y: 60)))
        #expect(canvas.document.elements.isEmpty)

        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 120, y: 100)))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 180, y: 160)))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 180, y: 160)))

        #expect(canvas.document.elements == [
            .shape(ShapeAnnotation(
                kind: .rectangle,
                rect: CGRect(x: 120, y: 140, width: 60, height: 60)
            ))
        ])
    }

    @Test("Annotation rectangles standardize every drag direction")
    func annotationRectangleStandardizesDragDirection() {
        let expected = CGRect(x: 20, y: 10, width: 100, height: 80)

        #expect(
            AnnotationGeometry.rectangle(
                from: CGPoint(x: 20, y: 10),
                to: CGPoint(x: 120, y: 90)
            ) == expected
        )
        #expect(
            AnnotationGeometry.rectangle(
                from: CGPoint(x: 120, y: 90),
                to: CGPoint(x: 20, y: 10)
            ) == expected
        )
    }

    @Test("Annotation undo removes one user action")
    func annotationDocumentUndoIsActionBased() {
        var document = AnnotationDocument()
        document.append(.text(TextAnnotation(
            text: "备注",
            origin: CGPoint(x: 12, y: 18)
        )))
        document.append(.shape(ShapeAnnotation(
            kind: .ellipse,
            rect: CGRect(x: 4, y: 6, width: 80, height: 44)
        )))

        #expect(document.elements.count == 2)
        #expect(document.undo() == .shape(ShapeAnnotation(
            kind: .ellipse,
            rect: CGRect(x: 4, y: 6, width: 80, height: 44)
        )))
        #expect(document.elements.count == 1)
    }

    @Test("Line annotations preserve direction and arrow choice")
    func lineAnnotationsKeepTheirEndpoints() {
        var document = AnnotationDocument()
        let plainLine = LineAnnotation(
            start: CGPoint(x: 12, y: 24),
            end: CGPoint(x: 180, y: 90),
            hasArrowhead: false
        )
        let arrowLine = LineAnnotation(
            start: CGPoint(x: 180, y: 90),
            end: CGPoint(x: 30, y: 160),
            hasArrowhead: true
        )
        document.append(.line(plainLine))
        document.append(.line(arrowLine))

        #expect(document.elements == [.line(plainLine), .line(arrowLine)])
        #expect(document.undo() == .line(arrowLine))
    }

    @Test("Advanced editor starts without an active drawing tool")
    @MainActor
    func annotationCanvasStartsNeutral() {
        let image = makeAnnotationTestImage(text: "CLIP")
        let canvas = AnnotationCanvasView(
            image: image,
            frame: CGRect(x: 0, y: 0, width: 640, height: 240)
        )

        #expect(canvas.tool == nil)
    }

    @Test("OCR recognizes selected pixels locally")
    @MainActor
    func localOCRRecognizesReadableText() async throws {
        let image = makeAnnotationTestImage(text: "CLIP OCR 123")
        let recognized = try await OCRTextRecognizer.recognize(image)

        #expect(recognized.localizedCaseInsensitiveContains("CLIP"))
        #expect(recognized.contains("123"))
    }

    @Test("Download writer saves PNGs without overwriting")
    func downloadWriterCreatesUniquePNGFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = makeAnnotationTestImage(text: "CLIP")
        let date = Date(timeIntervalSince1970: 0)
        let first = try await CaptureDownloadWriter.write(
            image,
            pixelsPerPoint: 2,
            to: directory,
            date: date
        )
        let second = try await CaptureDownloadWriter.write(
            image,
            to: directory,
            date: date
        )

        #expect(first.pathExtension == "png")
        #expect(second.pathExtension == "png")
        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        let retinaImage = try #require(NSImage(contentsOf: first))
        #expect(retinaImage.size == NSSize(width: 700, height: 180))
    }

    @Test("Processing returns before its deadline")
    func processingReturnsBeforeDeadline() async throws {
        let value = try await withProcessingDeadline(
            nanoseconds: 1_000_000_000
        ) {
            42
        }

        #expect(value == 42)
    }

    @Test("Processing deadline fails visibly instead of waiting forever")
    func processingDeadlineStopsWaiting() async {
        await #expect(throws: ClipError.processingTimedOut) {
            try await withProcessingDeadline(nanoseconds: 20_000_000) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 42
            }
        }
    }

    @Test("Selection rectangles standardize every drag direction")
    func selectionRectangleStandardizesDragDirection() {
        let expected = CGRect(x: -120, y: 40, width: 200, height: 180)

        #expect(
            SelectionGeometry.rectangle(
                from: CGPoint(x: -120, y: 40),
                to: CGPoint(x: 80, y: 220)
            ) == expected
        )
        #expect(
            SelectionGeometry.rectangle(
                from: CGPoint(x: 80, y: 220),
                to: CGPoint(x: -120, y: 40)
            ) == expected
        )
    }

    @Test("Committed selection aligns every edge to the screen point grid")
    func committedSelectionAlignsToScreenPointGrid() {
        let bounds = CGRect(x: -1_000, y: 0, width: 2_500, height: 1_200)
        let selection = CGRect(x: -120.2, y: 40.2, width: 200.6, height: 180.6)

        #expect(
            SelectionGeometry.captureAligned(selection, within: bounds)
                == CGRect(x: -120, y: 40, width: 200, height: 181)
        )
    }

    @Test("Hot-key descriptors render native menu equivalents")
    func hotKeyDescriptorRendersMenuEquivalent() {
        let descriptor = HotKeyDescriptor(
            keyCode: UInt32(kVK_ANSI_K),
            carbonModifiers: UInt32(controlKey | optionKey | shiftKey)
        )

        #expect(descriptor.displayString == "⌃⌥⇧K")
        #expect(descriptor.appKitKeyEquivalent == "k")
        #expect(descriptor.cocoaModifiers == [.control, .option, .shift])
    }

    @Test("The two actions reject the same stored shortcut")
    func shortcutPreferencesRejectDuplicateActionShortcut() {
        let originalRegion = HotKeyPreferences.region
        let originalScrolling = HotKeyPreferences.scrolling
        defer {
            HotKeyPreferences.setRegion(originalRegion)
            HotKeyPreferences.setScrolling(originalScrolling)
        }

        let region = HotKeyDescriptor(
            keyCode: UInt32(kVK_ANSI_R),
            carbonModifiers: UInt32(controlKey | optionKey)
        )
        let scrolling = HotKeyDescriptor(
            keyCode: UInt32(kVK_ANSI_S),
            carbonModifiers: UInt32(controlKey | optionKey)
        )
        HotKeyPreferences.setRegion(region)
        HotKeyPreferences.setScrolling(scrolling)

        #expect(!HotKeyPreferences.canAssign(scrolling, to: .region))
        #expect(!HotKeyPreferences.canAssign(region, to: .scrolling))
        #expect(HotKeyPreferences.canAssign(region, to: .region))
        #expect(HotKeyPreferences.canAssign(scrolling, to: .scrolling))
    }

}

private func makeSolidColorImage(
    width: Int,
    height: Int,
    color: NSColor
) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func makeAnnotationTestImage(text: String) -> CGImage {
    let width = 1400
    let height = 360
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    (text as NSString).draw(
        at: NSPoint(x: 72, y: 118),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 92, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
    )
    graphicsContext.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}
