import CoreGraphics
import Foundation

public enum FixedTopRegionPolicy: Sendable, Equatable {
    case none
    case fixed(height: Int)
    case automatic(maximumHeight: Int)
}

public struct ScrollStitchConfiguration: Sendable, Equatable {
    public var minimumOverlap: Int
    public var minimumScrollStep: Int
    public var maximumScrollStep: Int?
    public var minimumConfidence: Double
    public var noChangeSimilarity: Double
    public var requiredConsecutiveUnchangedFrames: Int
    public var fixedTopRegion: FixedTopRegionPolicy
    public var fixedRowSimilarity: Double
    public var ambiguityTolerance: Double
    public var changedPixelThreshold: Int
    public var maximumChangedPixelRatio: Double
    public var horizontalSampleStride: Int
    public var verticalSampleStride: Int
    public var maximumOutputHeight: Int
    public var maximumOutputPixelCount: Int

    public init(
        minimumOverlap: Int = 48,
        minimumScrollStep: Int = 1,
        maximumScrollStep: Int? = nil,
        minimumConfidence: Double = 0.94,
        noChangeSimilarity: Double = 0.998,
        requiredConsecutiveUnchangedFrames: Int = 2,
        fixedTopRegion: FixedTopRegionPolicy = .automatic(maximumHeight: 240),
        fixedRowSimilarity: Double = 0.995,
        ambiguityTolerance: Double = 0.002,
        changedPixelThreshold: Int = 12,
        maximumChangedPixelRatio: Double = 0.02,
        horizontalSampleStride: Int = 2,
        verticalSampleStride: Int = 2,
        maximumOutputHeight: Int = 100_000,
        maximumOutputPixelCount: Int = 50_000_000
    ) {
        self.minimumOverlap = minimumOverlap
        self.minimumScrollStep = minimumScrollStep
        self.maximumScrollStep = maximumScrollStep
        self.minimumConfidence = minimumConfidence
        self.noChangeSimilarity = noChangeSimilarity
        self.requiredConsecutiveUnchangedFrames = requiredConsecutiveUnchangedFrames
        self.fixedTopRegion = fixedTopRegion
        self.fixedRowSimilarity = fixedRowSimilarity
        self.ambiguityTolerance = ambiguityTolerance
        self.changedPixelThreshold = changedPixelThreshold
        self.maximumChangedPixelRatio = maximumChangedPixelRatio
        self.horizontalSampleStride = horizontalSampleStride
        self.verticalSampleStride = verticalSampleStride
        self.maximumOutputHeight = maximumOutputHeight
        self.maximumOutputPixelCount = maximumOutputPixelCount
    }
}

public struct ScrollStitchTransition: Sendable, Equatable {
    public let frameIndex: Int
    public let scrollStep: Int
    public let overlapHeight: Int
    public let appendedHeight: Int
    public let fixedTopHeight: Int
    public let confidence: Double
    public let runnerUpScrollStep: Int?
    public let runnerUpConfidence: Double
    public let changedPixelRatio: Double
}

public struct ScrollStitchResult: @unchecked Sendable {
    public let image: CGImage
    public let transitions: [ScrollStitchTransition]
    public let sourceFrameCount: Int
    public let skippedUnchangedFrameIndices: [Int]

    public var minimumConfidence: Double {
        transitions.map(\.confidence).min() ?? 1
    }
}

public enum ScrollFrameDisposition: Sendable, Equatable {
    case initial
    case appended(ScrollStitchTransition)
    case unchanged(consecutiveCount: Int)
    case duplicateBottom(consecutiveCount: Int)
}

public struct ScrollStitchProgress: Sendable, Equatable {
    public let frameIndex: Int
    public let sourceFrameCount: Int
    public let estimatedOutputHeight: Int
    public let disposition: ScrollFrameDisposition
}

/// A failure never carries a partially stitched image. Callers retain the
/// source `CGImage` values and can expose or persist those original frames.
public enum ScrollStitchError: Error, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case insufficientFrames
    case unreadableFrame(index: Int)
    case frameSizeMismatch(index: Int, expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
    case noChange
    case noValidOverlap(frameIndex: Int)
    case lowConfidence(frameIndex: Int, confidence: Double, required: Double)
    case ambiguousOverlap(frameIndex: Int, confidence: Double, runnerUpConfidence: Double)
    case changingContent(frameIndex: Int, changedPixelRatio: Double, maximumAllowed: Double)
    case unexpectedScrollDirection(frameIndex: Int)
    case bottomNotConfirmed
    case outputTooLarge(width: Int, height: Int, maximumHeight: Int, maximumPixelCount: Int)
    case outputCreationFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            "Invalid stitch configuration: \(message)"
        case .insufficientFrames:
            "At least two captured frames are required."
        case let .unreadableFrame(index):
            "Captured frame \(index) could not be converted to pixels."
        case let .frameSizeMismatch(index, expectedWidth, expectedHeight, actualWidth, actualHeight):
            "Captured frame \(index) is \(actualWidth)x\(actualHeight); expected \(expectedWidth)x\(expectedHeight)."
        case .noChange:
            "The captured region did not change after scrolling."
        case let .noValidOverlap(frameIndex):
            "No valid vertical overlap was found for frame \(frameIndex)."
        case let .lowConfidence(frameIndex, confidence, required):
            "Frame \(frameIndex) overlap confidence \(confidence) is below the required \(required)."
        case let .ambiguousOverlap(frameIndex, confidence, runnerUpConfidence):
            "Frame \(frameIndex) has ambiguous overlap candidates (\(confidence) and \(runnerUpConfidence))."
        case let .changingContent(frameIndex, changedPixelRatio, maximumAllowed):
            "Frame \(frameIndex) changed across \(changedPixelRatio) of the overlap; the maximum allowed is \(maximumAllowed)."
        case let .unexpectedScrollDirection(frameIndex):
            "Frame \(frameIndex) moved opposite to the expected scrolling direction."
        case .bottomNotConfirmed:
            "The bottom of the scrolling content has not been confirmed by repeated unchanged frames."
        case let .outputTooLarge(width, height, maximumHeight, maximumPixelCount):
            "The stitched output \(width)x\(height) exceeds the limits of height \(maximumHeight) and \(maximumPixelCount) pixels."
        case .outputCreationFailed:
            "The stitched image could not be created."
        }
    }
}

public struct ScrollStitcher: Sendable {
    public let configuration: ScrollStitchConfiguration

    public init(configuration: ScrollStitchConfiguration = .init()) {
        self.configuration = configuration
    }

    public func stitch(_ frames: [CGImage]) throws -> ScrollStitchResult {
        guard frames.count >= 2 else {
            throw ScrollStitchError.insufficientFrames
        }
        var session = try ScrollStitchSession(configuration: configuration)
        for frame in frames {
            _ = try session.ingest(frame)
        }
        return try session.finalize(requireConfirmedBottom: false)
    }

    /// Stitches in natural top-to-bottom order regardless of whether the user
    /// scrolled toward later or earlier content. The strict one-direction
    /// stitch remains available for callers that already know the direction.
    public func stitchInferringDirection(_ frames: [CGImage]) throws -> ScrollStitchResult {
        do {
            return try stitch(frames)
        } catch {
            let forwardError = error
            guard Self.canRetryInReverse(after: forwardError) else {
                throw forwardError
            }

            do {
                return try stitch(Array(frames.reversed()))
            } catch {
                let reverseError = error
                if Self.failureFrameIndex(reverseError) > Self.failureFrameIndex(forwardError) {
                    throw reverseError
                }
                throw forwardError
            }
        }
    }

    private static func canRetryInReverse(after error: Error) -> Bool {
        switch error as? ScrollStitchError {
        case .noChange,
             .noValidOverlap,
             .lowConfidence,
             .ambiguousOverlap,
             .changingContent,
             .unexpectedScrollDirection:
            return true
        case .none,
             .invalidConfiguration,
             .insufficientFrames,
             .unreadableFrame,
             .frameSizeMismatch,
             .bottomNotConfirmed,
             .outputTooLarge,
             .outputCreationFailed:
            return false
        }
    }

    private static func failureFrameIndex(_ error: Error) -> Int {
        switch error as? ScrollStitchError {
        case let .unreadableFrame(index),
             let .frameSizeMismatch(index, _, _, _, _),
             let .noValidOverlap(index),
             let .lowConfidence(index, _, _),
             let .ambiguousOverlap(index, _, _),
             let .changingContent(index, _, _),
             let .unexpectedScrollDirection(index):
            return index
        default:
            return 0
        }
    }

    fileprivate func validateConfiguration() throws {
        guard configuration.minimumOverlap > 0 else {
            throw ScrollStitchError.invalidConfiguration("minimumOverlap must be positive")
        }
        guard configuration.minimumScrollStep > 0 else {
            throw ScrollStitchError.invalidConfiguration("minimumScrollStep must be positive")
        }
        guard configuration.requiredConsecutiveUnchangedFrames > 0 else {
            throw ScrollStitchError.invalidConfiguration("requiredConsecutiveUnchangedFrames must be positive")
        }
        if let maximum = configuration.maximumScrollStep,
           maximum < configuration.minimumScrollStep {
            throw ScrollStitchError.invalidConfiguration("maximumScrollStep must not be smaller than minimumScrollStep")
        }
        guard (0...1).contains(configuration.minimumConfidence),
              (0...1).contains(configuration.noChangeSimilarity),
              (0...1).contains(configuration.fixedRowSimilarity),
              (0...1).contains(configuration.ambiguityTolerance),
              (0...1).contains(configuration.maximumChangedPixelRatio) else {
            throw ScrollStitchError.invalidConfiguration("similarity values must be between zero and one")
        }
        guard (0...255).contains(configuration.changedPixelThreshold) else {
            throw ScrollStitchError.invalidConfiguration("changedPixelThreshold must be between zero and 255")
        }
        guard configuration.horizontalSampleStride > 0, configuration.verticalSampleStride > 0 else {
            throw ScrollStitchError.invalidConfiguration("sample strides must be positive")
        }
        guard configuration.maximumOutputHeight > 0, configuration.maximumOutputPixelCount > 0 else {
            throw ScrollStitchError.invalidConfiguration("output limits must be positive")
        }
        switch configuration.fixedTopRegion {
        case .none:
            break
        case let .fixed(height):
            guard height >= 0 else {
                throw ScrollStitchError.invalidConfiguration("fixed top height cannot be negative")
            }
        case let .automatic(maximumHeight):
            guard maximumHeight >= 0 else {
                throw ScrollStitchError.invalidConfiguration("automatic fixed top maximum cannot be negative")
            }
        }
    }

    fileprivate func framesAreUnchanged(_ previous: PixelFrame, _ current: PixelFrame) -> Bool {
        similarity(
            previous,
            current,
            previousStartY: 0,
            currentStartY: 0,
            height: previous.height
        ) >= configuration.noChangeSimilarity
    }

    fileprivate func transition(
        previous: PixelFrame,
        current: PixelFrame,
        frameIndex: Int
    ) throws -> (transition: ScrollStitchTransition, appendStartY: Int) {
        let fixedTopHeight = detectFixedTopHeight(previous: previous, current: current)
        let candidate = try bestOverlap(
            previous: previous,
            current: current,
            fixedTopHeight: fixedTopHeight,
            frameIndex: frameIndex
        )

        guard candidate.confidence >= configuration.minimumConfidence else {
            if let reverseCandidate = try? bestOverlap(
                previous: current,
                current: previous,
                fixedTopHeight: fixedTopHeight,
                frameIndex: frameIndex
            ),
               reverseCandidate.confidence >= configuration.minimumConfidence,
               reverseCandidate.confidence - reverseCandidate.runnerUpConfidence > configuration.ambiguityTolerance {
                throw ScrollStitchError.unexpectedScrollDirection(frameIndex: frameIndex)
            }
            throw ScrollStitchError.lowConfidence(
                frameIndex: frameIndex,
                confidence: candidate.confidence,
                required: configuration.minimumConfidence
            )
        }

        if candidate.confidence - candidate.runnerUpConfidence <= configuration.ambiguityTolerance {
            throw ScrollStitchError.ambiguousOverlap(
                frameIndex: frameIndex,
                confidence: candidate.confidence,
                runnerUpConfidence: candidate.runnerUpConfidence
            )
        }

        guard candidate.changedPixelRatio <= configuration.maximumChangedPixelRatio else {
            throw ScrollStitchError.changingContent(
                frameIndex: frameIndex,
                changedPixelRatio: candidate.changedPixelRatio,
                maximumAllowed: configuration.maximumChangedPixelRatio
            )
        }

        let appendStartY = fixedTopHeight + candidate.overlapHeight
        let appendedHeight = current.height - appendStartY
        guard appendedHeight > 0 else {
            throw ScrollStitchError.noValidOverlap(frameIndex: frameIndex)
        }

        return (
            ScrollStitchTransition(
                frameIndex: frameIndex,
                scrollStep: candidate.scrollStep,
                overlapHeight: candidate.overlapHeight,
                appendedHeight: appendedHeight,
                fixedTopHeight: fixedTopHeight,
                confidence: candidate.confidence,
                runnerUpScrollStep: candidate.runnerUpScrollStep,
                runnerUpConfidence: candidate.runnerUpConfidence,
                changedPixelRatio: candidate.changedPixelRatio
            ),
            appendStartY
        )
    }

    private func detectFixedTopHeight(previous: PixelFrame, current: PixelFrame) -> Int {
        let maximumAllowed = max(0, previous.height - configuration.minimumOverlap - configuration.minimumScrollStep)
        switch configuration.fixedTopRegion {
        case .none:
            return 0
        case let .fixed(height):
            return min(height, maximumAllowed)
        case let .automatic(maximumHeight):
            let searchHeight = min(maximumHeight, maximumAllowed)
            guard searchHeight > 0 else { return 0 }

            var prefix = 0
            for y in 0..<searchHeight {
                let rowSimilarity = similarity(
                    previous,
                    current,
                    previousStartY: y,
                    currentStartY: y,
                    height: 1,
                    verticalStride: 1
                )
                guard rowSimilarity >= configuration.fixedRowSimilarity else { break }
                prefix = y + 1
            }
            return prefix
        }
    }

    private func bestOverlap(
        previous: PixelFrame,
        current: PixelFrame,
        fixedTopHeight: Int,
        frameIndex: Int
    ) throws -> OverlapCandidate {
        let contentHeight = previous.height - fixedTopHeight
        // A tiny overlap is not evidence of continuity on sparse interfaces:
        // a short strip of empty background can match almost anywhere. Keep at
        // least one fifth of the viewport in every candidate while preserving
        // the explicit pixel minimum for small/test images.
        let effectiveMinimumOverlap = max(
            configuration.minimumOverlap,
            contentHeight / 5
        )
        let maximumFromOverlap = contentHeight - effectiveMinimumOverlap
        let maximumStep = min(configuration.maximumScrollStep ?? maximumFromOverlap, maximumFromOverlap)
        guard maximumStep >= configuration.minimumScrollStep else {
            throw ScrollStitchError.noValidOverlap(frameIndex: frameIndex)
        }

        var coarseCandidates: [(step: Int, similarity: Double)] = []
        coarseCandidates.reserveCapacity(maximumStep - configuration.minimumScrollStep + 1)

        for step in configuration.minimumScrollStep...maximumStep {
            if step.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            let overlap = contentHeight - step
            let horizontalStride = max(configuration.horizontalSampleStride, max(1, previous.width / 32))
            let verticalStride = max(configuration.verticalSampleStride, max(1, overlap / 32))
            let score = comparison(
                previous,
                current,
                previousStartY: fixedTopHeight + step,
                currentStartY: fixedTopHeight,
                height: overlap,
                horizontalStride: horizontalStride,
                verticalStride: verticalStride
            ).similarity
            coarseCandidates.append((step, score))
        }

        coarseCandidates.sort {
            if $0.similarity == $1.similarity { return $0.step < $1.step }
            return $0.similarity > $1.similarity
        }
        guard !coarseCandidates.isEmpty else {
            throw ScrollStitchError.noValidOverlap(frameIndex: frameIndex)
        }

        // Coarse sampling only nominates candidates. Compare the strongest
        // candidates at the configured density before ranking them; comparing
        // an exact best score with a coarse runner-up can falsely report an
        // ambiguity on text-heavy Retina screenshots.
        let refinementCount = min(12, coarseCandidates.count)
        var refinedCandidates: [(step: Int, score: ComparisonScore)] = []
        refinedCandidates.reserveCapacity(refinementCount)
        for candidate in coarseCandidates.prefix(refinementCount) {
            try Task.checkCancellation()
            let overlap = contentHeight - candidate.step
            let score = comparison(
                previous,
                current,
                previousStartY: fixedTopHeight + candidate.step,
                currentStartY: fixedTopHeight,
                height: overlap
            )
            refinedCandidates.append((candidate.step, score))
        }
        refinedCandidates.sort {
            if $0.score.similarity == $1.score.similarity { return $0.step < $1.step }
            return $0.score.similarity > $1.score.similarity
        }
        guard let refinedBest = refinedCandidates.first else {
            throw ScrollStitchError.noValidOverlap(frameIndex: frameIndex)
        }

        let overlap = contentHeight - refinedBest.step
        let best = refinedBest.score
        let runnerUp = refinedCandidates.dropFirst().first?.score.similarity ?? 0

        return OverlapCandidate(
            scrollStep: refinedBest.step,
            overlapHeight: overlap,
            confidence: best.similarity,
            runnerUpScrollStep: refinedCandidates.dropFirst().first?.step,
            runnerUpConfidence: runnerUp,
            changedPixelRatio: best.changedPixelRatio
        )
    }

    private func similarity(
        _ lhs: PixelFrame,
        _ rhs: PixelFrame,
        previousStartY: Int,
        currentStartY: Int,
        height: Int,
        verticalStride: Int? = nil
    ) -> Double {
        comparison(
            lhs,
            rhs,
            previousStartY: previousStartY,
            currentStartY: currentStartY,
            height: height,
            horizontalStride: configuration.horizontalSampleStride,
            verticalStride: verticalStride ?? configuration.verticalSampleStride
        ).similarity
    }

    private func comparison(
        _ lhs: PixelFrame,
        _ rhs: PixelFrame,
        previousStartY: Int,
        currentStartY: Int,
        height: Int,
        horizontalStride: Int? = nil,
        verticalStride: Int? = nil
    ) -> ComparisonScore {
        guard height > 0 else { return .zero }
        let xStride = horizontalStride ?? configuration.horizontalSampleStride
        let yStride = verticalStride ?? configuration.verticalSampleStride
        var difference: UInt64 = 0
        var componentCount: UInt64 = 0
        var changedPixelCount: UInt64 = 0
        var pixelCount: UInt64 = 0

        var relativeY = 0
        while relativeY < height {
            let lhsRow = (previousStartY + relativeY) * lhs.bytesPerRow
            let rhsRow = (currentStartY + relativeY) * rhs.bytesPerRow
            var x = 0
            while x < lhs.width {
                let lhsPixel = lhsRow + x * PixelFrame.bytesPerPixel
                let rhsPixel = rhsRow + x * PixelFrame.bytesPerPixel
                var maximumComponentDifference = 0
                for component in 0..<3 {
                    let componentDifference = abs(Int(lhs.bytes[lhsPixel + component]) - Int(rhs.bytes[rhsPixel + component]))
                    difference += UInt64(componentDifference)
                    maximumComponentDifference = max(maximumComponentDifference, componentDifference)
                    componentCount += 1
                }
                if maximumComponentDifference > configuration.changedPixelThreshold {
                    changedPixelCount += 1
                }
                pixelCount += 1
                x += xStride
            }
            relativeY += yStride
        }

        guard componentCount > 0, pixelCount > 0 else { return .zero }
        return ComparisonScore(
            similarity: 1 - Double(difference) / (Double(componentCount) * 255),
            changedPixelRatio: Double(changedPixelCount) / Double(pixelCount)
        )
    }

    fileprivate func checkedAdding(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw ScrollStitchError.outputTooLarge(
                width: 0,
                height: Int.max,
                maximumHeight: configuration.maximumOutputHeight,
                maximumPixelCount: configuration.maximumOutputPixelCount
            )
        }
        return value
    }

    fileprivate func enforceOutputLimit(width: Int, height: Int) throws {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow,
              height <= configuration.maximumOutputHeight,
              pixels <= configuration.maximumOutputPixelCount else {
            throw ScrollStitchError.outputTooLarge(
                width: width,
                height: height,
                maximumHeight: configuration.maximumOutputHeight,
                maximumPixelCount: configuration.maximumOutputPixelCount
            )
        }
    }
}

/// Incremental form of the stitcher for capture loops. It decodes and compares
/// each accepted frame once instead of rebuilding the entire image after every
/// scroll event. The session keeps normalized pixels, not the original
/// `CGImage` values; the capture coordinator remains responsible for retaining
/// source frames until success so a failure can preserve them.
public struct ScrollStitchSession: Sendable {
    private let stitcher: ScrollStitcher
    private var firstWidth: Int?
    private var firstHeight: Int?
    private var previous: PixelFrame?
    private var output: [UInt8] = []
    private var outputHeight = 0
    private var transitions: [ScrollStitchTransition] = []
    private var skippedUnchangedFrameIndices: [Int] = []
    private var sourceFrameCount = 0
    private var consecutiveUnchangedFrameCount = 0
    private var isBottomConfirmed = false

    public init(configuration: ScrollStitchConfiguration = .init()) throws {
        let stitcher = ScrollStitcher(configuration: configuration)
        try stitcher.validateConfiguration()
        self.stitcher = stitcher
    }

    /// Ingests one frame in capture order. Keep a session owned by one task;
    /// its value can safely be transferred across actor boundaries.
    public mutating func ingest(_ image: CGImage) throws -> ScrollStitchProgress {
        try Task.checkCancellation()
        let frameIndex = sourceFrameCount
        if previous == nil {
            try stitcher.enforceOutputLimit(width: image.width, height: image.height)
            guard let frame = PixelFrame(image: image) else {
                throw ScrollStitchError.unreadableFrame(index: frameIndex)
            }
            firstWidth = frame.width
            firstHeight = frame.height
            previous = frame
            output = frame.bytes
            outputHeight = frame.height
            sourceFrameCount = 1
            return ScrollStitchProgress(
                frameIndex: frameIndex,
                sourceFrameCount: sourceFrameCount,
                estimatedOutputHeight: outputHeight,
                disposition: .initial
            )
        }

        guard let width = firstWidth, let height = firstHeight, let previous else {
            throw ScrollStitchError.outputCreationFailed
        }
        guard image.width == width, image.height == height else {
            throw ScrollStitchError.frameSizeMismatch(
                index: frameIndex,
                expectedWidth: width,
                expectedHeight: height,
                actualWidth: image.width,
                actualHeight: image.height
            )
        }
        guard let current = PixelFrame(image: image) else {
            throw ScrollStitchError.unreadableFrame(index: frameIndex)
        }

        if stitcher.framesAreUnchanged(previous, current) {
            sourceFrameCount += 1
            skippedUnchangedFrameIndices.append(frameIndex)
            consecutiveUnchangedFrameCount += 1
            let disposition: ScrollFrameDisposition
            if !transitions.isEmpty,
               consecutiveUnchangedFrameCount >= stitcher.configuration.requiredConsecutiveUnchangedFrames {
                isBottomConfirmed = true
                disposition = .duplicateBottom(consecutiveCount: consecutiveUnchangedFrameCount)
            } else {
                disposition = .unchanged(consecutiveCount: consecutiveUnchangedFrameCount)
            }
            return ScrollStitchProgress(
                frameIndex: frameIndex,
                sourceFrameCount: sourceFrameCount,
                estimatedOutputHeight: outputHeight,
                disposition: disposition
            )
        }

        let analysis = try stitcher.transition(
            previous: previous,
            current: current,
            frameIndex: frameIndex
        )
        let proposedHeight = try stitcher.checkedAdding(outputHeight, analysis.transition.appendedHeight)
        try stitcher.enforceOutputLimit(width: width, height: proposedHeight)

        let byteStart = analysis.appendStartY * current.bytesPerRow
        output.append(contentsOf: current.bytes[byteStart...])
        outputHeight = proposedHeight
        transitions.append(analysis.transition)
        self.previous = current
        sourceFrameCount += 1
        consecutiveUnchangedFrameCount = 0
        isBottomConfirmed = false

        return ScrollStitchProgress(
            frameIndex: frameIndex,
            sourceFrameCount: sourceFrameCount,
            estimatedOutputHeight: outputHeight,
            disposition: .appended(analysis.transition)
        )
    }

    /// Produces the image only after a verified transition exists. Capture
    /// loops should keep the default and finalize only after `duplicateBottom`.
    /// Offline callers with an already-bounded frame set may opt out.
    public func finalize(requireConfirmedBottom: Bool = true) throws -> ScrollStitchResult {
        guard sourceFrameCount >= 2 else {
            throw ScrollStitchError.insufficientFrames
        }
        guard !transitions.isEmpty else {
            throw ScrollStitchError.noChange
        }
        if requireConfirmedBottom, !isBottomConfirmed {
            throw ScrollStitchError.bottomNotConfirmed
        }
        guard let width = firstWidth,
              let image = PixelFrame.makeImage(width: width, height: outputHeight, bytes: output) else {
            throw ScrollStitchError.outputCreationFailed
        }
        return ScrollStitchResult(
            image: image,
            transitions: transitions,
            sourceFrameCount: sourceFrameCount,
            skippedUnchangedFrameIndices: skippedUnchangedFrameIndices
        )
    }
}

private struct OverlapCandidate {
    let scrollStep: Int
    let overlapHeight: Int
    let confidence: Double
    let runnerUpScrollStep: Int?
    let runnerUpConfidence: Double
    let changedPixelRatio: Double
}

private struct ComparisonScore {
    static let zero = ComparisonScore(similarity: 0, changedPixelRatio: 1)

    let similarity: Double
    let changedPixelRatio: Double
}

struct PixelFrame: Sendable {
    static let bytesPerPixel = 4
    static let colorSpace = CGColorSpaceCreateDeviceRGB()
    static let bitmapInfo = CGBitmapInfo(rawValue:
        CGImageAlphaInfo.premultipliedLast.rawValue |
        CGBitmapInfo.byteOrder32Big.rawValue
    )

    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    init?(image: CGImage) {
        guard image.width > 0, image.height > 0 else { return nil }
        let imageWidth = image.width
        let imageHeight = image.height
        let (rowBytes, rowOverflow) = imageWidth.multipliedReportingOverflow(by: Self.bytesPerPixel)
        let (byteCount, countOverflow) = rowBytes.multipliedReportingOverflow(by: imageHeight)
        guard !rowOverflow, !countOverflow else { return nil }

        var buffer = [UInt8](repeating: 0, count: byteCount)
        let rendered = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: imageWidth,
                    height: imageHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: rowBytes,
                    space: Self.colorSpace,
                    bitmapInfo: Self.bitmapInfo.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            return true
        }
        guard rendered else { return nil }
        width = imageWidth
        height = imageHeight
        bytesPerRow = rowBytes
        bytes = buffer
    }

    static func makeImage(width: Int, height: Int, bytes: [UInt8]) -> CGImage? {
        let bytesPerRow = width * bytesPerPixel
        guard bytes.count == bytesPerRow * height else { return nil }
        return makeImage(width: width, height: height, data: Data(bytes))
    }

    static func makeImage(width: Int, height: Int, data: Data) -> CGImage? {
        let bytesPerRow = width * bytesPerPixel
        guard data.count == bytesPerRow * height,
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
