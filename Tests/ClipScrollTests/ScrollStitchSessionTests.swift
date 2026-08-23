import CoreGraphics
import Foundation
import Testing
@testable import ClipScroll

@Suite("Incremental scroll stitch session")
struct ScrollStitchSessionTests {
    @Test func requiresTwoUnchangedFramesToConfirmDuplicateBottom() throws {
        let content = (0..<14).map(sessionColor)
        let first = sessionFrame(width: 8, rows: Array(content[0..<8]))
        let second = sessionFrame(width: 8, rows: Array(content[4..<12]))
        var session = try ScrollStitchSession(configuration: sessionConfiguration())
        requireSendable(session)
        requireSendable(first)

        let initial = try session.ingest(first)
        let appended = try session.ingest(second)
        let firstRepeat = try session.ingest(second)

        #expect(initial.disposition == .initial)
        guard case let .appended(transition) = appended.disposition else {
            Issue.record("Expected appended transition")
            return
        }
        #expect(transition.appendedHeight == 4)
        #expect(firstRepeat.disposition == .unchanged(consecutiveCount: 1))
        #expect(throws: ScrollStitchError.bottomNotConfirmed) {
            try session.finalize()
        }

        let confirmed = try session.ingest(second)
        #expect(confirmed.disposition == .duplicateBottom(consecutiveCount: 2))

        let result = try session.finalize()
        #expect(result.image.height == 12)
        #expect(result.sourceFrameCount == 4)
        #expect(result.skippedUnchangedFrameIndices == [2, 3])
    }

    @Test func laterMovementResetsAnUnchangedCandidate() throws {
        let content = (0..<18).map(sessionColor)
        let first = sessionFrame(width: 8, rows: Array(content[0..<8]))
        let second = sessionFrame(width: 8, rows: Array(content[4..<12]))
        let third = sessionFrame(width: 8, rows: Array(content[8..<16]))
        var session = try ScrollStitchSession(configuration: sessionConfiguration())

        _ = try session.ingest(first)
        _ = try session.ingest(second)
        let delayed = try session.ingest(second)
        let resumed = try session.ingest(third)
        let newCandidate = try session.ingest(third)

        #expect(delayed.disposition == .unchanged(consecutiveCount: 1))
        guard case .appended = resumed.disposition else {
            Issue.record("Expected capture to resume after a transient duplicate")
            return
        }
        #expect(newCandidate.disposition == .unchanged(consecutiveCount: 1))
    }

    @Test func cancelledTaskStopsBeforeMutatingSession() async throws {
        let frame = sessionFrame(width: 8, rows: (0..<8).map(sessionColor))
        let task = Task { () throws -> ScrollStitchProgress in
            var session = try ScrollStitchSession(configuration: sessionConfiguration())
            try await Task.sleep(for: .milliseconds(50))
            return try session.ingest(frame)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

private func requireSendable<T: Sendable>(_ value: T) {}

private func sessionConfiguration() -> ScrollStitchConfiguration {
    ScrollStitchConfiguration(
        minimumOverlap: 3,
        minimumScrollStep: 1,
        maximumScrollStep: 5,
        minimumConfidence: 0.99,
        noChangeSimilarity: 0.999,
        requiredConsecutiveUnchangedFrames: 2,
        fixedTopRegion: .none,
        fixedRowSimilarity: 0.999,
        ambiguityTolerance: 0.000_1,
        horizontalSampleStride: 1,
        verticalSampleStride: 1,
        maximumOutputHeight: 1_000,
        maximumOutputPixelCount: 1_000_000
    )
}

private struct SessionRGBA {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

private func sessionColor(_ index: Int) -> SessionRGBA {
    SessionRGBA(
        red: UInt8((index * 67 + 13) % 256),
        green: UInt8((index * 109 + 41) % 256),
        blue: UInt8((index * 151 + 79) % 256)
    )
}

private func sessionFrame(width: Int, rows: [SessionRGBA]) -> CGImage {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * rows.count * 4)
    for row in rows {
        for _ in 0..<width {
            bytes += [row.red, row.green, row.blue, 255]
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
            CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}
