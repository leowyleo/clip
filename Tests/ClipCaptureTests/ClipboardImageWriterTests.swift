import AppKit
import Foundation
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

    #expect(representation.pixelsWide == 11)
    #expect(representation.pixelsHigh == 7)
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
