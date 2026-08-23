import CoreGraphics
import Foundation

public struct ContinuousScrollConfiguration: Sendable, Equatable {
    public var minimumOverlapRatio: Double
    public var minimumCorrelation: Double
    public var ambiguityTolerance: Double
    public var maximumDynamicFeatureRatio: Double
    public var keyframeDistanceRatio: Double
    public var maximumOutputHeight: Int
    public var maximumOutputPixelCount: Int

    public init(
        minimumOverlapRatio: Double = 0.20,
        minimumCorrelation: Double = 0.90,
        ambiguityTolerance: Double = 0.015,
        maximumDynamicFeatureRatio: Double = 0.20,
        keyframeDistanceRatio: Double = 0.50,
        maximumOutputHeight: Int = 100_000,
        maximumOutputPixelCount: Int = 24_000_000
    ) {
        self.minimumOverlapRatio = minimumOverlapRatio
        self.minimumCorrelation = minimumCorrelation
        self.ambiguityTolerance = ambiguityTolerance
        self.maximumDynamicFeatureRatio = maximumDynamicFeatureRatio
        self.keyframeDistanceRatio = keyframeDistanceRatio
        self.maximumOutputHeight = maximumOutputHeight
        self.maximumOutputPixelCount = maximumOutputPixelCount
    }
}

public enum ContinuousScrollFrameDisposition: Sendable, Equatable {
    case initial
    case unchanged
    case moved(delta: Int, globalOrigin: Int, retained: Bool)
    case ignoredUnreliable
}

public struct ContinuousScrollProgress: Sendable, Equatable {
    public let sourceFrameCount: Int
    public let retainedFrameCount: Int
    public let coveredHeight: Int
    public let disposition: ContinuousScrollFrameDisposition
}

public struct ContinuousScrollResult: @unchecked Sendable {
    public let image: CGImage
    public let sourceFrameCount: Int
    public let retainedFrameCount: Int
    public let coveredHeight: Int
    public let minimumCorrelation: Double
}

/// Tracks a scrolling viewport in a global vertical content coordinate system.
/// Frames may move in either direction; revisiting covered coordinates updates
/// tracking but adds no duplicate output rows.
public struct ContinuousScrollSession: Sendable {
    private let configuration: ContinuousScrollConfiguration
    private var previousPlacement: Placement?
    private var retainedPlacements: [Placement] = []
    private var topExtreme: Placement?
    private var bottomExtreme: Placement?
    private var lastRetainedOrigin = 0
    private var lastDirection = 0
    private var sourceFrameCount = 0
    private var didMove = false
    private var minimumOrigin = 0
    private var maximumEnd = 0

    public init(configuration: ContinuousScrollConfiguration = .init()) throws {
        guard (0.20...0.50).contains(configuration.minimumOverlapRatio),
              (0...1).contains(configuration.minimumCorrelation),
              (0...1).contains(configuration.ambiguityTolerance),
              (0...1).contains(configuration.maximumDynamicFeatureRatio),
              (0.05...0.50).contains(configuration.keyframeDistanceRatio),
              configuration.maximumOutputHeight > 0,
              configuration.maximumOutputPixelCount > 0 else {
            throw ScrollStitchError.invalidConfiguration(
                "continuous scroll configuration is outside its safe range"
            )
        }
        self.configuration = configuration
    }

    public mutating func ingest(_ image: CGImage) throws -> ContinuousScrollProgress {
        try Task.checkCancellation()
        guard let frame = PixelFrame(image: image) else {
            throw ScrollStitchError.unreadableFrame(index: sourceFrameCount)
        }
        let profile = EdgeProfile(frame: frame)
        let frameIndex = sourceFrameCount
        sourceFrameCount += 1

        guard let previousPlacement else {
            try enforceOutputLimit(width: frame.width, height: frame.height)
            let placement = Placement(
                origin: 0,
                frame: frame,
                profile: profile,
                frameIndex: frameIndex,
                confidence: 1
            )
            self.previousPlacement = placement
            retainedPlacements = [placement]
            topExtreme = placement
            bottomExtreme = placement
            maximumEnd = frame.height
            return progress(.initial)
        }

        guard frame.width == previousPlacement.frame.width,
              frame.height == previousPlacement.frame.height else {
            throw ScrollStitchError.frameSizeMismatch(
                index: frameIndex,
                expectedWidth: previousPlacement.frame.width,
                expectedHeight: previousPlacement.frame.height,
                actualWidth: frame.width,
                actualHeight: frame.height
            )
        }

        if Self.sampledMeanDifference(previousPlacement.frame, frame) < 1.25 {
            return progress(.unchanged)
        }

        guard let motion = MotionEstimator.estimate(
            previous: previousPlacement.profile,
            current: profile,
            configuration: configuration
        ) else {
            return progress(.ignoredUnreliable)
        }

        let globalOrigin = previousPlacement.origin + motion.delta
        let placement = Placement(
            origin: globalOrigin,
            frame: frame,
            profile: profile,
            frameIndex: frameIndex,
            confidence: motion.correlation
        )
        let oldMinimum = minimumOrigin
        let oldMaximum = maximumEnd
        let newMinimum = min(minimumOrigin, globalOrigin)
        let newMaximum = max(maximumEnd, globalOrigin + frame.height)
        // Enforce the complete covered range while frames arrive. Waiting until
        // finalize would retain hundreds of megabytes only to reject the image.
        try enforceOutputLimit(width: frame.width, height: newMaximum - newMinimum)

        // The configured keyframe distance is only a memory target. If fast
        // motion crosses the largest verifiable gap between samples, retain the
        // previous placement as a bridge before advancing the tracking anchor.
        let maximumRetainedGap = max(
            1,
            Int(floor(
                Double(frame.height) * (1 - configuration.minimumOverlapRatio)
            ))
        )
        if abs(globalOrigin - lastRetainedOrigin) > maximumRetainedGap {
            retain(previousPlacement: previousPlacement)
        }

        self.previousPlacement = placement
        didMove = true

        let direction = motion.delta.signum()
        if lastDirection != 0, direction != lastDirection {
            retain(previousPlacement: previousPlacement)
        }
        lastDirection = direction

        minimumOrigin = newMinimum
        maximumEnd = newMaximum

        if globalOrigin < oldMinimum {
            topExtreme = placement
        }
        if globalOrigin + frame.height > oldMaximum {
            bottomExtreme = placement
        }

        let keyframeDistance = max(
            8,
            Int(Double(frame.height) * configuration.keyframeDistanceRatio)
        )
        let extendsCoverage = globalOrigin < oldMinimum
            || globalOrigin + frame.height > oldMaximum
        let shouldRetain = extendsCoverage
            && abs(globalOrigin - lastRetainedOrigin) >= keyframeDistance
        if shouldRetain {
            retainedPlacements.append(placement)
            lastRetainedOrigin = globalOrigin
        }

        return progress(
            .moved(
                delta: motion.delta,
                globalOrigin: globalOrigin,
                retained: shouldRetain
            )
        )
    }

    public func finalize() throws -> ContinuousScrollResult {
        guard sourceFrameCount >= 2, didMove else {
            throw ScrollStitchError.noChange
        }

        var placements = retainedPlacements
        if let topExtreme { placements.append(topExtreme) }
        if let bottomExtreme { placements.append(bottomExtreme) }
        if let previousPlacement { placements.append(previousPlacement) }
        placements = Self.deduplicatedPlacements(placements)
        guard placements.count >= 2, let first = placements.first else {
            throw ScrollStitchError.noChange
        }

        let width = first.frame.width
        let viewportHeight = first.frame.height
        let expectedOutputHeight = maximumEnd - minimumOrigin
        try enforceOutputLimit(width: width, height: expectedOutputHeight)
        let requiredOverlap = max(
            1,
            Int(ceil(Double(viewportHeight) * configuration.minimumOverlapRatio))
        )
        let (expectedByteCount, byteCountOverflow) = width
            .multipliedReportingOverflow(by: PixelFrame.bytesPerPixel)
        let (reservedByteCount, reserveOverflow) = expectedByteCount
            .multipliedReportingOverflow(by: expectedOutputHeight)
        guard !byteCountOverflow, !reserveOverflow else {
            throw ScrollStitchError.outputTooLarge(
                width: width,
                height: expectedOutputHeight,
                maximumHeight: configuration.maximumOutputHeight,
                maximumPixelCount: configuration.maximumOutputPixelCount
            )
        }
        var output = Data()
        output.reserveCapacity(reservedByteCount)
        output.append(contentsOf: first.frame.bytes)
        var outputHeight = viewportHeight
        var coverageEnd = first.origin + viewportHeight
        var lastPlacement = first
        var acceptedCorrelations: [Double] = []

        for placement in placements.dropFirst() {
            try Task.checkCancellation()
            let placementEnd = placement.origin + viewportHeight
            guard placementEnd > coverageEnd else { continue }

            let overlap = coverageEnd - placement.origin
            guard overlap >= requiredOverlap, overlap < viewportHeight else {
                throw ScrollStitchError.noValidOverlap(frameIndex: placement.frameIndex)
            }
            let expectedDelta = placement.origin - lastPlacement.origin
            let verification = MotionEstimator.score(
                previous: lastPlacement.profile,
                current: placement.profile,
                delta: expectedDelta,
                verticalStride: 1
            )
            guard verification.correlation >= configuration.minimumCorrelation else {
                throw ScrollStitchError.lowConfidence(
                    frameIndex: placement.frameIndex,
                    confidence: verification.correlation,
                    required: configuration.minimumCorrelation
                )
            }
            guard verification.dynamicFeatureRatio <= configuration.maximumDynamicFeatureRatio else {
                throw ScrollStitchError.changingContent(
                    frameIndex: placement.frameIndex,
                    changedPixelRatio: verification.dynamicFeatureRatio,
                    maximumAllowed: configuration.maximumDynamicFeatureRatio
                )
            }

            let sourceRow = overlap
            output.append(contentsOf: placement.frame.bytes[(sourceRow * placement.frame.bytesPerRow)...])
            outputHeight += viewportHeight - sourceRow
            try enforceOutputLimit(width: width, height: outputHeight)
            coverageEnd = placementEnd
            lastPlacement = placement
            acceptedCorrelations.append(verification.correlation)
        }

        guard !acceptedCorrelations.isEmpty,
              let image = PixelFrame.makeImage(width: width, height: outputHeight, data: output) else {
            throw ScrollStitchError.outputCreationFailed
        }
        return ContinuousScrollResult(
            image: image,
            sourceFrameCount: sourceFrameCount,
            retainedFrameCount: placements.count,
            coveredHeight: outputHeight,
            minimumCorrelation: acceptedCorrelations.min() ?? 1
        )
    }

    public func retainedSourceImages() -> [CGImage] {
        var placements = retainedPlacements
        if let topExtreme { placements.append(topExtreme) }
        if let bottomExtreme { placements.append(bottomExtreme) }
        if let previousPlacement { placements.append(previousPlacement) }
        return Self.deduplicatedPlacements(placements).compactMap {
            PixelFrame.makeImage(
                width: $0.frame.width,
                height: $0.frame.height,
                bytes: $0.frame.bytes
            )
        }
    }

    private mutating func retain(previousPlacement: Placement?) {
        guard let previousPlacement,
              !retainedPlacements.contains(where: {
                $0.origin == previousPlacement.origin
              }) else { return }
        retainedPlacements.append(previousPlacement)
        lastRetainedOrigin = previousPlacement.origin
    }

    private func progress(
        _ disposition: ContinuousScrollFrameDisposition
    ) -> ContinuousScrollProgress {
        ContinuousScrollProgress(
            sourceFrameCount: sourceFrameCount,
            retainedFrameCount: retainedPlacements.count,
            coveredHeight: maximumEnd - minimumOrigin,
            disposition: disposition
        )
    }

    private func enforceOutputLimit(width: Int, height: Int) throws {
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

    private static func sampledMeanDifference(_ lhs: PixelFrame, _ rhs: PixelFrame) -> Double {
        let xStride = max(1, lhs.width / 64)
        let yStride = max(1, lhs.height / 64)
        var difference: UInt64 = 0
        var componentCount: UInt64 = 0
        var y = 0
        while y < lhs.height {
            let lhsRow = y * lhs.bytesPerRow
            let rhsRow = y * rhs.bytesPerRow
            var x = 0
            while x < lhs.width {
                let lhsPixel = lhsRow + x * PixelFrame.bytesPerPixel
                let rhsPixel = rhsRow + x * PixelFrame.bytesPerPixel
                for component in 0..<3 {
                    difference += UInt64(abs(
                        Int(lhs.bytes[lhsPixel + component])
                            - Int(rhs.bytes[rhsPixel + component])
                    ))
                    componentCount += 1
                }
                x += xStride
            }
            y += yStride
        }
        guard componentCount > 0 else { return 0 }
        return Double(difference) / Double(componentCount)
    }

    private static func deduplicatedPlacements(_ placements: [Placement]) -> [Placement] {
        var byOrigin: [Int: Placement] = [:]
        for placement in placements {
            if let existing = byOrigin[placement.origin],
               existing.confidence >= placement.confidence {
                continue
            }
            byOrigin[placement.origin] = placement
        }
        return byOrigin.values.sorted {
            if $0.origin == $1.origin { return $0.frameIndex < $1.frameIndex }
            return $0.origin < $1.origin
        }
    }
}

private struct Placement: Sendable {
    let origin: Int
    let frame: PixelFrame
    let profile: EdgeProfile
    let frameIndex: Int
    let confidence: Double
}

struct MotionEstimate {
    let delta: Int
    let correlation: Double
    let runnerUpCorrelation: Double
    let dynamicFeatureRatio: Double
}

struct MotionScore {
    static let invalid = MotionScore(correlation: -1, dynamicFeatureRatio: 1)

    let correlation: Double
    let dynamicFeatureRatio: Double
}

enum MotionEstimator {
    static func estimate(
        previous: EdgeProfile,
        current: EdgeProfile,
        configuration: ContinuousScrollConfiguration
    ) -> MotionEstimate? {
        guard previous.height == current.height,
              previous.columnCount == current.columnCount else { return nil }
        let minimumOverlap = Int(ceil(
            Double(previous.height) * configuration.minimumOverlapRatio
        ))
        let maximumDelta = previous.height - minimumOverlap
        guard maximumDelta >= 1 else { return nil }

        let coarseStep = max(1, previous.height / 240)
        var coarse: [(delta: Int, score: MotionScore)] = []
        var magnitude = 1
        while magnitude <= maximumDelta {
            for delta in [magnitude, -magnitude] {
                let score = score(
                    previous: previous,
                    current: current,
                    delta: delta,
                    verticalStride: 4,
                    horizontalStride: 4
                )
                if score.correlation.isFinite {
                    coarse.append((delta, score))
                }
            }
            magnitude += coarseStep
        }
        coarse.sort { $0.score.correlation > $1.score.correlation }
        guard !coarse.isEmpty else { return nil }

        var deltas = Set<Int>()
        for candidate in coarse.prefix(10) {
            let lower = max(-maximumDelta, candidate.delta - coarseStep)
            let upper = min(maximumDelta, candidate.delta + coarseStep)
            for delta in lower...upper where delta != 0 {
                deltas.insert(delta)
            }
        }

        var refined: [(delta: Int, score: MotionScore)] = deltas.map { delta in
            (
                delta,
                score(
                    previous: previous,
                    current: current,
                    delta: delta,
                    verticalStride: 1
                )
            )
        }
        refined.sort { $0.score.correlation > $1.score.correlation }
        guard let best = refined.first,
              best.score.correlation >= configuration.minimumCorrelation,
              best.score.dynamicFeatureRatio <= configuration.maximumDynamicFeatureRatio else {
            return nil
        }

        let peakRadius = max(2, coarseStep)
        let runnerUp = refined.first {
            abs($0.delta - best.delta) > peakRadius
        }
        let runnerUpCorrelation = runnerUp?.score.correlation ?? -1
        guard best.score.correlation - runnerUpCorrelation
                > configuration.ambiguityTolerance else {
            return nil
        }

        return MotionEstimate(
            delta: best.delta,
            correlation: best.score.correlation,
            runnerUpCorrelation: runnerUpCorrelation,
            dynamicFeatureRatio: best.score.dynamicFeatureRatio
        )
    }

    static func score(
        previous: EdgeProfile,
        current: EdgeProfile,
        delta: Int,
        verticalStride: Int,
        horizontalStride: Int = 1
    ) -> MotionScore {
        let magnitude = abs(delta)
        let overlap = previous.height - magnitude
        guard overlap > 0 else { return .invalid }
        let previousStart = max(0, delta)
        let currentStart = max(0, -delta)
        let relativeStart = max(
            0,
            1 - previousStart,
            1 - currentStart
        )
        let relativeEnd = min(
            overlap,
            previous.height - 1 - previousStart,
            current.height - 1 - currentStart
        )
        guard relativeEnd > relativeStart else { return .invalid }

        var sumPrevious = 0.0
        var sumCurrent = 0.0
        var sumPreviousSquared = 0.0
        var sumCurrentSquared = 0.0
        var sumProduct = 0.0
        var dynamicCount = 0
        var sampleCount = 0

        var relativeY = relativeStart
        while relativeY < relativeEnd {
            let previousRow = (previousStart + relativeY) * previous.columnCount
            let currentRow = (currentStart + relativeY) * current.columnCount
            var column = 0
            while column < previous.columnCount {
                let lhs = Double(previous.values[previousRow + column])
                let rhs = Double(current.values[currentRow + column])
                sumPrevious += lhs
                sumCurrent += rhs
                sumPreviousSquared += lhs * lhs
                sumCurrentSquared += rhs * rhs
                sumProduct += lhs * rhs
                if abs(lhs - rhs) > 36 {
                    dynamicCount += 1
                }
                sampleCount += 1
                column += max(1, horizontalStride)
            }
            relativeY += verticalStride
        }

        let normalizedHorizontalStride = max(1, horizontalStride)
        let sampledColumnCount = max(
            1,
            (previous.columnCount + normalizedHorizontalStride - 1)
                / normalizedHorizontalStride
        )
        guard sampleCount >= sampledColumnCount * 8 else { return .invalid }
        let count = Double(sampleCount)
        let covariance = sumProduct - (sumPrevious * sumCurrent / count)
        let previousVariance = sumPreviousSquared - (sumPrevious * sumPrevious / count)
        let currentVariance = sumCurrentSquared - (sumCurrent * sumCurrent / count)
        let denominator = sqrt(max(0, previousVariance * currentVariance))
        guard denominator > 0.000_001 else { return .invalid }
        return MotionScore(
            correlation: covariance / denominator,
            dynamicFeatureRatio: Double(dynamicCount) / count
        )
    }
}

struct EdgeProfile: Sendable {
    static let desiredColumns = 32
    static let samplesPerColumn = 8

    let height: Int
    let columnCount: Int
    let values: [Float]

    init(frame: PixelFrame) {
        height = frame.height
        columnCount = min(Self.desiredColumns, max(1, frame.width / 4))
        var values = [Float](repeating: 0, count: height * columnCount)
        let ignoredRightGutter = min(32, max(4, frame.width / 40))
        let analysisWidth = max(columnCount, frame.width - ignoredRightGutter)

        guard frame.width >= 3, frame.height >= 3 else {
            self.values = values
            return
        }

        for y in 1..<(frame.height - 1) {
            for column in 0..<columnCount {
                let startX = column * analysisWidth / columnCount
                let endX = max(startX + 1, (column + 1) * analysisWidth / columnCount)
                let step = max(1, (endX - startX) / Self.samplesPerColumn)
                var total = 0
                var count = 0
                var x = max(1, startX)
                while x < min(frame.width - 1, endX) {
                    let horizontal = abs(
                        Self.luminance(frame, x: x + 1, y: y)
                            - Self.luminance(frame, x: x - 1, y: y)
                    )
                    let vertical = abs(
                        Self.luminance(frame, x: x, y: y + 1)
                            - Self.luminance(frame, x: x, y: y - 1)
                    )
                    total += horizontal + vertical
                    count += 1
                    x += step
                }
                if count > 0 {
                    values[y * columnCount + column] = Float(total) / Float(count)
                }
            }
        }
        self.values = values
    }

    private static func luminance(_ frame: PixelFrame, x: Int, y: Int) -> Int {
        let pixel = y * frame.bytesPerRow + x * PixelFrame.bytesPerPixel
        return (
            77 * Int(frame.bytes[pixel])
                + 150 * Int(frame.bytes[pixel + 1])
                + 29 * Int(frame.bytes[pixel + 2])
        ) >> 8
    }
}
