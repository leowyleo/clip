import CoreGraphics
import Foundation
import Testing
@testable import ClipScroll

@Suite("Scroll stitcher")
struct ScrollStitcherTests {
    @Test func stitchesVerticalFramesAndKeepsFixedHeaderOnce() throws {
        let header = [RGBA(240, 20, 20), RGBA(220, 30, 30)]
        let content = (0..<18).map(patternedColor)
        let frames = [0, 4, 8].map {
            makeFrame(width: 9, header: header, content: Array(content[$0..<($0 + 6)]))
        }
        let stitcher = ScrollStitcher(configuration: testConfiguration())

        let result = try stitcher.stitch(frames)

        #expect(result.image.width == 9)
        #expect(result.image.height == 16)
        #expect(result.transitions.map(\.fixedTopHeight) == [2, 2])
        #expect(result.transitions.map(\.appendedHeight) == [4, 4])
        #expect(result.transitions.map(\.overlapHeight) == [2, 2])
        #expect(abs(result.minimumConfidence - 1) < 0.000_001)
        #expect(readFirstPixelOfEachRow(result.image) == header + Array(content[0..<14]))
    }

    @Test func skipsDuplicateFrameAndContinuesWithNextChangedFrame() throws {
        let header = [RGBA(10, 10, 10)]
        let content = (0..<12).map(patternedColor)
        let first = makeFrame(width: 7, header: header, content: Array(content[0..<6]))
        let next = makeFrame(width: 7, header: header, content: Array(content[3..<9]))
        let stitcher = ScrollStitcher(configuration: testConfiguration(minimumOverlap: 2, maximumScrollStep: 4))

        let result = try stitcher.stitch([first, first, next])

        #expect(result.skippedUnchangedFrameIndices == [1])
        #expect(result.transitions.count == 1)
        #expect(result.transitions[0].frameIndex == 2)
        #expect(result.image.height == 10)
        #expect(readFirstPixelOfEachRow(result.image) == header + Array(content[0..<9]))
    }

    @Test func allDuplicateFramesFailAsNoChange() throws {
        let content = (0..<8).map(patternedColor)
        let frame = makeFrame(width: 6, header: [], content: content)
        let stitcher = ScrollStitcher(configuration: testConfiguration())

        #expect(throws: ScrollStitchError.noChange) {
            try stitcher.stitch([frame, frame])
        }
    }

    @Test func unrelatedFramesFailOnLowConfidence() throws {
        let firstRows = (0..<10).map(patternedColor)
        let secondRows: [RGBA] = (0..<10).map { index in
            let red = UInt8((index * 11 + 201) % 256)
            let green = UInt8((index * 47 + 3) % 256)
            let blue = UInt8((index * 83 + 91) % 256)
            return RGBA(red, green, blue)
        }
        let first = makeFrame(width: 11, header: [], content: firstRows)
        let second = makeFrame(width: 11, header: [], content: secondRows)
        var configuration = testConfiguration(minimumOverlap: 3, maximumScrollStep: 6)
        configuration.minimumConfidence = 0.999
        configuration.ambiguityTolerance = 0

        do {
            _ = try ScrollStitcher(configuration: configuration).stitch([first, second])
            Issue.record("Expected lowConfidence")
        } catch let ScrollStitchError.lowConfidence(frameIndex, confidence, required) {
            #expect(frameIndex == 1)
            #expect(confidence < required)
        } catch {
            Issue.record("Expected lowConfidence, received \(error)")
        }
    }

    @Test func rejectsOutputBeforeExceedingConfiguredLimit() throws {
        let content = (0..<12).map(patternedColor)
        let first = makeFrame(width: 8, header: [], content: Array(content[0..<8]))
        let second = makeFrame(width: 8, header: [], content: Array(content[4..<12]))
        var configuration = testConfiguration(minimumOverlap: 3, maximumScrollStep: 5)
        configuration.maximumOutputHeight = 10

        do {
            _ = try ScrollStitcher(configuration: configuration).stitch([first, second])
            Issue.record("Expected outputTooLarge")
        } catch let ScrollStitchError.outputTooLarge(width, height, maximumHeight, _) {
            #expect(width == 8)
            #expect(height == 12)
            #expect(maximumHeight == 10)
        } catch {
            Issue.record("Expected outputTooLarge, received \(error)")
        }
    }

    @Test func repeatedVisualPatternFailsAsAmbiguous() throws {
        let alternating = (0..<10).map { index in
            index.isMultiple(of: 2) ? RGBA(20, 20, 20) : RGBA(230, 230, 230)
        }
        let first = makeFrame(width: 8, header: [], content: alternating)
        let second = makeFrame(width: 8, header: [], content: alternating)
        var configuration = testConfiguration(minimumOverlap: 3, maximumScrollStep: 6)
        configuration.noChangeSimilarity = 1

        // Make one pixel different so this is not classified as an unchanged
        // frame. Several vertical offsets remain equally plausible.
        var changedRows = alternating
        changedRows[9] = RGBA(100, 120, 140)
        let changed = makeFrame(width: 8, header: [], content: changedRows)

        do {
            _ = try ScrollStitcher(configuration: configuration).stitch([first, second, changed])
            Issue.record("Expected ambiguousOverlap")
        } catch ScrollStitchError.ambiguousOverlap {
            // Expected fail-closed result.
        } catch {
            Issue.record("Expected ambiguousOverlap, received \(error)")
        }
    }

    @Test func oppositeMovementFailsWithExplicitDirectionError() throws {
        let content = (0..<18).map(patternedColor)
        let laterViewport = makeFrame(width: 10, header: [], content: Array(content[4..<12]))
        let earlierViewport = makeFrame(width: 10, header: [], content: Array(content[0..<8]))
        var configuration = testConfiguration(minimumOverlap: 3, maximumScrollStep: 5)
        configuration.fixedTopRegion = .none

        #expect(throws: ScrollStitchError.unexpectedScrollDirection(frameIndex: 1)) {
            try ScrollStitcher(configuration: configuration).stitch([laterViewport, earlierViewport])
        }
    }

    @Test func inferredDirectionStitchesFramesCapturedTowardEarlierContent() throws {
        let content = (0..<18).map(patternedColor)
        let earlier = makeFrame(width: 10, header: [], content: Array(content[0..<8]))
        let middle = makeFrame(width: 10, header: [], content: Array(content[4..<12]))
        let later = makeFrame(width: 10, header: [], content: Array(content[8..<16]))
        var configuration = testConfiguration(minimumOverlap: 3, maximumScrollStep: 5)
        configuration.fixedTopRegion = .none

        let result = try ScrollStitcher(configuration: configuration)
            .stitchInferringDirection([later, middle, earlier])

        #expect(result.image.height == 16)
        #expect(readFirstPixelOfEachRow(result.image) == Array(content[0..<16]))
    }

    @Test func localizedChangingContentFailsInsteadOfProducingImage() throws {
        let width = 20
        let content = (0..<18).map { y in
            (0..<width).map { x in patternedColor(y * width + x) }
        }
        let first = makePixelImage(rows: Array(content[0..<10]))
        var changedViewport = Array(content[4..<14])

        // Ten percent of the verified overlap changes independently while the
        // remaining pixels still identify the correct scroll offset exactly.
        for y in 0..<6 {
            for x in 0..<2 {
                changedViewport[y][x] = RGBA(255, 255, 255)
            }
        }
        let changed = makePixelImage(rows: changedViewport)
        var configuration = testConfiguration(minimumOverlap: 4, maximumScrollStep: 6)
        configuration.fixedTopRegion = .none
        configuration.minimumConfidence = 0.94
        configuration.maximumChangedPixelRatio = 0.02

        do {
            _ = try ScrollStitcher(configuration: configuration).stitch([first, changed])
            Issue.record("Expected changingContent")
        } catch let ScrollStitchError.changingContent(frameIndex, ratio, maximumAllowed) {
            #expect(frameIndex == 1)
            #expect(ratio > maximumAllowed)
        } catch {
            Issue.record("Expected changingContent, received \(error)")
        }
    }

    @Test func mediumViewportUsesBoundedCandidateSearchAndStitchesExactly() throws {
        let width = 320
        let viewportHeight = 240
        let scrollStep = 120
        let content = (0..<(viewportHeight + scrollStep)).map { y in
            (0..<width).map { x in patternedPixel(x: x, y: y) }
        }
        let first = makePixelImage(rows: Array(content[0..<viewportHeight]))
        let second = makePixelImage(rows: Array(content[scrollStep..<(scrollStep + viewportHeight)]))
        var configuration = ScrollStitchConfiguration()
        configuration.fixedTopRegion = .none
        configuration.minimumOverlap = 80
        configuration.maximumScrollStep = 160

        let result = try ScrollStitcher(configuration: configuration).stitch([first, second])

        #expect(result.image.width == width)
        #expect(result.image.height == viewportHeight + scrollStep)
        #expect(result.transitions[0].appendedHeight == scrollStep)
        #expect(result.transitions[0].changedPixelRatio == 0)
    }

    @Test func retinaScaleViewportStitchesWithoutChangingTheSearchContract() throws {
        let width = 1_280
        let viewportHeight = 720
        let scrollStep = 432
        let content = (0..<(viewportHeight + scrollStep)).map { y in
            (0..<width).map { x in patternedPixel(x: x, y: y) }
        }
        let first = makePixelImage(rows: Array(content[0..<viewportHeight]))
        let second = makePixelImage(rows: Array(content[scrollStep..<(scrollStep + viewportHeight)]))
        var configuration = ScrollStitchConfiguration()
        configuration.fixedTopRegion = .none

        let result = try ScrollStitcher(configuration: configuration).stitch([first, second])

        #expect(result.image.width == width)
        #expect(result.image.height == viewportHeight + scrollStep)
        #expect(result.transitions[0].appendedHeight == scrollStep)
    }
}

private struct RGBA: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

private func patternedColor(_ index: Int) -> RGBA {
    RGBA(
        UInt8((index * 67 + 13) % 256),
        UInt8((index * 109 + 41) % 256),
        UInt8((index * 151 + 79) % 256)
    )
}

private func patternedPixel(x: Int, y: Int) -> RGBA {
    var value = UInt64(x) &* 0x9E3779B185EBCA87
    value ^= UInt64(y) &* 0xC2B2AE3D27D4EB4F
    value ^= value >> 30
    value = value &* 0xBF58476D1CE4E5B9
    value ^= value >> 27
    value = value &* 0x94D049BB133111EB
    value ^= value >> 31
    return RGBA(UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16))
}

private func makeFrame(width: Int, header: [RGBA], content: [RGBA]) -> CGImage {
    makeImage(width: width, rows: header + content)
}

private func makeImage(width: Int, rows: [RGBA]) -> CGImage {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * rows.count * 4)
    for color in rows {
        for _ in 0..<width {
            bytes.append(color.red)
            bytes.append(color.green)
            bytes.append(color.blue)
            bytes.append(color.alpha)
        }
    }

    let data = Data(bytes) as CFData
    let provider = CGDataProvider(data: data)!
    let bitmapInfo = CGBitmapInfo(rawValue:
        CGImageAlphaInfo.premultipliedLast.rawValue |
        CGBitmapInfo.byteOrder32Big.rawValue
    )
    return CGImage(
        width: width,
        height: rows.count,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func makePixelImage(rows: [[RGBA]]) -> CGImage {
    let width = rows.first?.count ?? 0
    #expect(width > 0)
    #expect(rows.allSatisfy { $0.count == width })

    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * rows.count * 4)
    for row in rows {
        for color in row {
            bytes.append(color.red)
            bytes.append(color.green)
            bytes.append(color.blue)
            bytes.append(color.alpha)
        }
    }

    let data = Data(bytes) as CFData
    let provider = CGDataProvider(data: data)!
    let bitmapInfo = CGBitmapInfo(rawValue:
        CGImageAlphaInfo.premultipliedLast.rawValue |
        CGBitmapInfo.byteOrder32Big.rawValue
    )
    return CGImage(
        width: width,
        height: rows.count,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func readFirstPixelOfEachRow(_ image: CGImage) -> [RGBA] {
    let data = image.dataProvider!.data! as Data
    return (0..<image.height).map { row in
        let offset = row * image.bytesPerRow
        return RGBA(data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
    }
}

private func testConfiguration(
    minimumOverlap: Int = 2,
    maximumScrollStep: Int = 5
) -> ScrollStitchConfiguration {
    ScrollStitchConfiguration(
        minimumOverlap: minimumOverlap,
        minimumScrollStep: 1,
        maximumScrollStep: maximumScrollStep,
        minimumConfidence: 0.99,
        noChangeSimilarity: 0.999,
        fixedTopRegion: .automatic(maximumHeight: 3),
        fixedRowSimilarity: 0.999,
        ambiguityTolerance: 0.000_1,
        horizontalSampleStride: 1,
        verticalSampleStride: 1,
        maximumOutputHeight: 1_000,
        maximumOutputPixelCount: 1_000_000
    )
}
