import AppKit
import Carbon.HIToolbox
import ClipCore
import Testing
@testable import ClipApp

@Suite("Clip app shell logic", .serialized)
struct ClipAppLogicTests {
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
