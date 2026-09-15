import CoreGraphics
import Foundation
import Testing
@testable import ClipCapture

@Test func compositorPreservesImageOrientationAtTopLeftDestination() throws {
    let source = try #require(twoRowTestImage())
    let context = try #require(ScreenCaptureKitRegionCapturer.makeContext(width: 1, height: 4))

    ScreenCaptureKitRegionCapturer.draw(
        source,
        in: CGRect(x: 0, y: 0, width: 1, height: 2),
        canvasHeight: 4,
        context: context
    )

    let output = try #require(context.makeImage())
    let bytes = try #require(output.dataProvider?.data as? Data)
    let rowBytes = output.bytesPerRow
    #expect(Array(bytes[0..<4]) == [255, 0, 0, 255])
    #expect(Array(bytes[rowBytes..<(rowBytes + 4)]) == [0, 0, 255, 255])
    #expect(Array(bytes[(rowBytes * 2)..<(rowBytes * 2 + 4)]) == [0, 0, 0, 0])
    #expect(Array(bytes[(rowBytes * 3)..<(rowBytes * 3 + 4)]) == [0, 0, 0, 0])
}

@Test func compositorPreservesSinglePixelDividersWithoutInterpolation() throws {
    let source = try #require(threeColumnDividerImage())
    let context = try #require(ScreenCaptureKitRegionCapturer.makeContext(width: 3, height: 1))

    ScreenCaptureKitRegionCapturer.draw(
        source,
        in: CGRect(x: 0, y: 0, width: 3, height: 1),
        canvasHeight: 1,
        context: context
    )

    let output = try #require(context.makeImage())
    let bytes = try #require(output.dataProvider?.data as? Data)
    #expect(Array(bytes[0..<12]) == [
        255, 255, 255, 255,
        0, 0, 0, 255,
        255, 255, 255, 255
    ])
}

private func twoRowTestImage() -> CGImage? {
    // CGImage scan lines: red top row, blue bottom row.
    let bytes: [UInt8] = [
        255, 0, 0, 255,
        0, 0, 255, 255
    ]
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
        return nil
    }
    return CGImage(
        width: 1,
        height: 2,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

private func threeColumnDividerImage() -> CGImage? {
    let bytes: [UInt8] = [
        255, 255, 255, 255,
        0, 0, 0, 255,
        255, 255, 255, 255
    ]
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
        return nil
    }
    return CGImage(
        width: 3,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 12,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}
