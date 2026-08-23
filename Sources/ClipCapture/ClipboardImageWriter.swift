import AppKit
import ClipCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ClipboardImageError: LocalizedError, Equatable, Sendable {
    case invalidPNGData
    case encodingFailed
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPNGData:
            ClipLocalization.text(
                "The provided data is not a valid PNG image.",
                "提供的数据不是有效的 PNG 图片。"
            )
        case .encodingFailed:
            ClipLocalization.text(
                "The capture could not be encoded as PNG.",
                "无法将截图编码为 PNG。"
            )
        case .writeFailed:
            ClipLocalization.text(
                "The capture could not be written to the clipboard.",
                "无法将截图写入剪贴板。"
            )
        }
    }
}

public enum PNGImageEncoder {
    public static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ClipboardImageError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ClipboardImageError.encodingFailed
        }
        return data as Data
    }
}

@MainActor
public protocol PNGPasteboardProviding: AnyObject {
    func replaceContents(withPNG data: Data) -> Bool
}

@MainActor
public final class SystemPNGPasteboard: PNGPasteboardProviding {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func replaceContents(withPNG data: Data) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }
}

/// Writes one canonical PNG representation, whether callers start with PNG,
/// NSImage, or CGImage. This makes pasting deterministic across receiving apps.
@MainActor
public final class ClipboardImageWriter {
    private let pasteboard: any PNGPasteboardProviding

    public init(pasteboard: any PNGPasteboardProviding = SystemPNGPasteboard()) {
        self.pasteboard = pasteboard
    }

    public func write(pngData: Data) throws {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard pngData.starts(with: pngSignature), NSBitmapImageRep(data: pngData) != nil else {
            throw ClipboardImageError.invalidPNGData
        }
        guard pasteboard.replaceContents(withPNG: pngData) else {
            throw ClipboardImageError.writeFailed
        }
    }

    public func write(image: NSImage) throws {
        guard let pngData = Self.pngData(from: image) else {
            throw ClipboardImageError.encodingFailed
        }
        guard pasteboard.replaceContents(withPNG: pngData) else {
            throw ClipboardImageError.writeFailed
        }
    }

    public func write(cgImage: CGImage) throws {
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        try write(image: image)
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return representation.representation(using: .png, properties: [:])
    }
}
