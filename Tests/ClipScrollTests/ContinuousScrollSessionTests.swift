import CoreGraphics
import Foundation
import Testing
@testable import ClipScroll

@Suite("Continuous bidirectional scroll session")
struct ContinuousScrollSessionTests {
    @Test func composesFramesWhileMovingTowardLaterContent() throws {
        let content = makeContent(width: 96, height: 180)
        let frames = [0, 24, 48, 72].map {
            makeImage(rows: Array(content[$0..<($0 + 80)]))
        }
        let previous = PixelFrame(image: frames[0])!
        let current = PixelFrame(image: frames[1])!
        let rawOverlapMatches = (24..<80).allSatisfy { row in
            let previousRange = (row * previous.bytesPerRow)..<((row + 1) * previous.bytesPerRow)
            let currentRow = row - 24
            let currentRange = (currentRow * current.bytesPerRow)..<((currentRow + 1) * current.bytesPerRow)
            return previous.bytes[previousRange] == current.bytes[currentRange]
        }
        #expect(rawOverlapMatches)
        let previousProfile = EdgeProfile(frame: previous)
        let currentProfile = EdgeProfile(frame: current)
        let profileOverlapMatches = (25..<79).allSatisfy { row in
            let previousRange = (row * previousProfile.columnCount)..<((row + 1) * previousProfile.columnCount)
            let currentRow = row - 24
            let currentRange = (currentRow * currentProfile.columnCount)..<((currentRow + 1) * currentProfile.columnCount)
            return previousProfile.values[previousRange] == currentProfile.values[currentRange]
        }
        #expect(profileOverlapMatches)
        let score = MotionEstimator.score(
            previous: previousProfile,
            current: currentProfile,
            delta: 24,
            verticalStride: 1
        )
        #expect(score.correlation > 0.99)
        #expect(MotionEstimator.estimate(
            previous: previousProfile,
            current: currentProfile,
            configuration: .init()
        )?.delta == 24)
        var session = try ContinuousScrollSession()

        for frame in frames {
            _ = try session.ingest(frame)
        }
        let result = try session.finalize()

        #expect(result.image.height == 152)
        #expect(imageBytes(result.image) == imageBytes(makeImage(rows: Array(content[0..<152]))))
    }

    @Test func composesFramesWhileMovingTowardEarlierContent() throws {
        let content = makeContent(width: 96, height: 180)
        let frames = [72, 48, 24, 0].map {
            makeImage(rows: Array(content[$0..<($0 + 80)]))
        }
        var session = try ContinuousScrollSession()

        for frame in frames {
            _ = try session.ingest(frame)
        }
        let result = try session.finalize()

        #expect(result.image.height == 152)
        #expect(imageBytes(result.image) == imageBytes(makeImage(rows: Array(content[0..<152]))))
    }

    @Test func rollbackDoesNotDuplicateCoveredRows() throws {
        let content = makeContent(width: 96, height: 220)
        let offsets = [40, 64, 88, 64, 112, 136]
        var session = try ContinuousScrollSession()

        for offset in offsets {
            _ = try session.ingest(
                makeImage(rows: Array(content[offset..<(offset + 80)]))
            )
        }
        let result = try session.finalize()

        #expect(result.image.height == 176)
        #expect(imageBytes(result.image) == imageBytes(makeImage(rows: Array(content[40..<216]))))
    }

    @Test func fastSubthresholdStepsRetainAContinuousBridge() throws {
        let content = makeContent(width: 96, height: 240)
        let frames = [0, 36, 72, 108, 144].map {
            makeImage(rows: Array(content[$0..<($0 + 80)]))
        }
        var session = try ContinuousScrollSession()

        for frame in frames {
            _ = try session.ingest(frame)
        }
        let result = try session.finalize()

        #expect(result.image.height == 224)
        #expect(imageBytes(result.image) == imageBytes(makeImage(rows: Array(content[0..<224]))))
    }

    @Test func stationaryFramesDoNotProduceAnImage() throws {
        let content = makeContent(width: 96, height: 80)
        let frame = makeImage(rows: content)
        var session = try ContinuousScrollSession()
        _ = try session.ingest(frame)
        _ = try session.ingest(frame)

        #expect(throws: ScrollStitchError.noChange) {
            try session.finalize()
        }
    }

    @Test func rejectsExcessiveCoverageDuringIngest() throws {
        let content = makeContent(width: 96, height: 180)
        let configuration = ContinuousScrollConfiguration(
            maximumOutputHeight: 110,
            maximumOutputPixelCount: 1_000_000
        )
        var session = try ContinuousScrollSession(configuration: configuration)
        _ = try session.ingest(makeImage(rows: Array(content[0..<80])))
        _ = try session.ingest(makeImage(rows: Array(content[24..<104])))

        #expect(throws: ScrollStitchError.self) {
            try session.ingest(makeImage(rows: Array(content[48..<128])))
        }
    }
}

private struct ContinuousRGBA {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

private func makeContent(width: Int, height: Int) -> [[ContinuousRGBA]] {
    (0..<height).map { y in
        (0..<width).map { x in
            var value = UInt64(x + 1) &* 0x9E3779B185EBCA87
            value ^= UInt64(y + 7) &* 0xC2B2AE3D27D4EB4F
            value ^= value >> 29
            value = value &* 0xBF58476D1CE4E5B9
            value ^= value >> 31
            return ContinuousRGBA(
                red: UInt8(truncatingIfNeeded: value),
                green: UInt8(truncatingIfNeeded: value >> 8),
                blue: UInt8(truncatingIfNeeded: value >> 16)
            )
        }
    }
}

private func makeImage(rows: [[ContinuousRGBA]]) -> CGImage {
    let width = rows.first?.count ?? 0
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * rows.count * 4)
    for row in rows {
        for pixel in row {
            bytes.append(pixel.red)
            bytes.append(pixel.green)
            bytes.append(pixel.blue)
            bytes.append(255)
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: width,
        height: rows.count,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func imageBytes(_ image: CGImage) -> Data {
    image.dataProvider!.data! as Data
}
