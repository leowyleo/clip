import AppKit
import Foundation
import ImageIO
import Testing
@testable import ClipCapture

@MainActor
@Test func writesPNGDataToPasteboard() throws {
    let pasteboard = FakePNGPasteboard()
    let writer = ClipboardImageWriter(pasteboard: pasteboard)
    let image = NSImage(cgImage: makeTestImage(width: 2, height: 2), size: NSSize(width: 2, height: 2))
    let png = try #require(pngData(from: image))

    try writer.write(pngData: png)

    #expect(pasteboard.writes == [png])
}

@MainActor
@Test func convertsNSImageToPNGForPasteboard() throws {
    let pasteboard = FakePNGPasteboard()
    let writer = ClipboardImageWriter(pasteboard: pasteboard)
    let image = NSImage(cgImage: makeTestImage(width: 3, height: 2), size: NSSize(width: 3, height: 2))

    try writer.write(image: image)

    let written = try #require(pasteboard.writes.first)
    #expect(NSBitmapImageRep(data: written) != nil)
}

@MainActor
@Test func reportsInvalidPNGAndPasteboardFailure() throws {
    let rejectingPasteboard = FakePNGPasteboard(acceptWrites: false)
    let writer = ClipboardImageWriter(pasteboard: rejectingPasteboard)

    #expect(throws: ClipboardImageError.invalidPNGData) {
        try writer.write(pngData: Data("not an image".utf8))
    }

    let image = NSImage(cgImage: makeTestImage(), size: NSSize(width: 1, height: 1))
    let png = try #require(pngData(from: image))
    #expect(throws: ClipboardImageError.writeFailed) {
        try writer.write(pngData: png)
    }
}

@MainActor
@Test func systemPasteboardPublishesReadablePNGAndNSImage() throws {
    let name = NSPasteboard.Name("ClipCaptureTests.\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    defer {
        pasteboard.clearContents()
        pasteboard.releaseGlobally()
    }

    let writer = ClipboardImageWriter(pasteboard: SystemPNGPasteboard(pasteboard: pasteboard))
    let source = makeTestImage(width: 7, height: 5)
    try writer.write(cgImage: source)

    let png = try #require(pasteboard.data(forType: .png))
    let representation = try #require(NSBitmapImageRep(data: png))
    #expect(representation.pixelsWide == 7)
    #expect(representation.pixelsHigh == 5)
    #expect(NSImage(pasteboard: pasteboard) != nil)
}

@Test func encodesCGImageDirectlyAsPNG() throws {
    let data = try PNGImageEncoder.encode(makeTestImage(width: 11, height: 7))
    let representation = try #require(NSBitmapImageRep(data: data))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )

    #expect(representation.pixelsWide == 11)
    #expect(representation.pixelsHigh == 7)
    #expect(properties[kCGImagePropertyDPIWidth] as? Double == 72)
    #expect(properties[kCGImagePropertyDPIHeight] as? Double == 72)
}

@Test func encodesRetinaPNGWithoutChangingItsPixels() throws {
    let data = try PNGImageEncoder.encode(
        makeTestImage(width: 1_300, height: 800),
        pixelsPerPoint: 2
    )
    let representation = try #require(NSBitmapImageRep(data: data))
    let decodedImage = try #require(NSImage(data: data))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )

    #expect(representation.pixelsWide == 1_300)
    #expect(representation.pixelsHigh == 800)
    #expect(decodedImage.size == NSSize(width: 650, height: 400))
    #expect(properties[kCGImagePropertyDPIWidth] as? Double == 144)
    #expect(properties[kCGImagePropertyDPIHeight] as? Double == 144)
}

@Test func derivesIntegralRetinaScaleFromCapturePixelsAndSelectionPoints() {
    #expect(CaptureImageResolution.pixelsPerPoint(pixelWidth: 1_300, pointWidth: 650) == 2)
    #expect(CaptureImageResolution.pixelsPerPoint(pixelWidth: 1_301, pointWidth: 650.3) == 2)
    #expect(CaptureImageResolution.pixelsPerPoint(pixelWidth: 650, pointWidth: 650) == 1)
}

@MainActor
private final class FakePNGPasteboard: PNGPasteboardProviding {
    private(set) var writes: [Data] = []
    private let acceptWrites: Bool

    init(acceptWrites: Bool = true) {
        self.acceptWrites = acceptWrites
    }

    func replaceContents(withPNG data: Data) -> Bool {
        guard acceptWrites else {
            return false
        }
        writes.append(data)
        return true
    }
}

@MainActor
private func pngData(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else {
        return nil
    }
    return rep.representation(using: .png, properties: [:])
}
