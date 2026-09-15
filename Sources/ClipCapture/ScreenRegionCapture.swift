import ClipCore
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// A replaceable boundary around the macOS screenshot implementation.
public protocol ScreenRegionImageCapturing: Sendable {
    /// Captures a rectangle in Quartz global display coordinates (top-left origin).
    func capture(quartzRect: CGRect) async throws -> CGImage
}

/// Validates a user selection and authorization before crossing into the system capturer.
public struct ScreenRegionCaptureService: Sendable {
    private let permission: any ScreenRecordingPermissionProviding
    private let capturer: any ScreenRegionImageCapturing
    private let coordinateConverter: ScreenCoordinateConverter

    public init(
        permission: any ScreenRecordingPermissionProviding = SystemScreenRecordingPermission(),
        capturer: any ScreenRegionImageCapturing = ScreenCaptureKitRegionCapturer(),
        coordinateConverter: ScreenCoordinateConverter = ScreenCoordinateConverter()
    ) {
        self.permission = permission
        self.capturer = capturer
        self.coordinateConverter = coordinateConverter
    }

    /// Captures an AppKit-global selection. AppKit rectangles have their origin at
    /// the bottom-left of the main display and may extend onto any attached display.
    public func capture(region: CaptureRegion) async throws -> CGImage {
        guard region.isUsable, region.rect.hasFiniteComponents else {
            throw ClipError.invalidSelection
        }
        guard permission.isAuthorized() else {
            throw ClipError.screenRecordingPermissionDenied
        }

        let quartzRect = ScreenCaptureGeometry.alignedToPointGrid(
            coordinateConverter.quartzRect(fromAppKit: region.rect)
        )
        do {
            return try await capturer.capture(quartzRect: quartzRect)
        } catch let error as ClipError {
            throw error
        } catch {
            // Permission can be revoked after the initial preflight and before
            // ScreenCaptureKit produces the image. Preserve the actionable error.
            guard permission.isAuthorized() else {
                throw ClipError.screenRecordingPermissionDenied
            }
            throw ClipError.captureFailed
        }
    }
}

private extension CGRect {
    var hasFiniteComponents: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
    }
}

struct CaptureDisplay: Equatable, Sendable {
    var id: CGDirectDisplayID
    var frame: CGRect
    var scale: CGFloat
}

struct DisplayCaptureSlice: Equatable, Sendable {
    var displayID: CGDirectDisplayID
    var sourceRect: CGRect
    var destinationRect: CGRect
}

struct DisplayCapturePlan: Equatable, Sendable {
    var pixelWidth: Int
    var pixelHeight: Int
    var slices: [DisplayCaptureSlice]

    func isWithinLimits(maxDimension: Int, maxPixelCount: Int) -> Bool {
        guard pixelWidth > 0,
              pixelHeight > 0,
              pixelWidth <= maxDimension,
              pixelHeight <= maxDimension
        else {
            return false
        }
        return pixelHeight <= maxPixelCount / pixelWidth
    }
}

enum DisplayCapturePlanner {
    /// Plans display-local source rectangles and top-left-origin output rectangles.
    /// A single maximum scale keeps the final image aligned when Retina and standard
    /// displays are part of the same selection.
    static func plan(for rect: CGRect, displays: [CaptureDisplay]) -> DisplayCapturePlan? {
        let rect = rect.standardized
        guard rect.hasFiniteComponents, !rect.isEmpty else {
            return nil
        }
        let participatingDisplays = displays.filter {
            let intersection = $0.frame.intersection(rect)
            return !intersection.isNull && !intersection.isEmpty
        }
        guard !participatingDisplays.isEmpty else {
            return nil
        }

        let outputScale = participatingDisplays.map(\.scale).max() ?? 1
        guard outputScale.isFinite, outputScale > 0 else {
            return nil
        }

        let pixelWidthValue = ceil(rect.width * outputScale)
        let pixelHeightValue = ceil(rect.height * outputScale)
        guard pixelWidthValue.isFinite,
              pixelHeightValue.isFinite,
              pixelWidthValue > 0,
              pixelHeightValue > 0,
              pixelWidthValue <= CGFloat(Int.max),
              pixelHeightValue <= CGFloat(Int.max)
        else {
            return nil
        }
        let pixelWidth = Int(pixelWidthValue)
        let pixelHeight = Int(pixelHeightValue)

        let slices = participatingDisplays.compactMap { display -> DisplayCaptureSlice? in
            let intersection = display.frame.intersection(rect)
            guard !intersection.isNull, !intersection.isEmpty else {
                return nil
            }

            let sourceRect = CGRect(
                x: intersection.minX - display.frame.minX,
                y: intersection.minY - display.frame.minY,
                width: intersection.width,
                height: intersection.height
            )
            let destinationRect = CGRect(
                x: (intersection.minX - rect.minX) * outputScale,
                y: (intersection.minY - rect.minY) * outputScale,
                width: intersection.width * outputScale,
                height: intersection.height * outputScale
            )
            return DisplayCaptureSlice(
                displayID: display.id,
                sourceRect: sourceRect,
                destinationRect: destinationRect
            )
        }

        guard !slices.isEmpty else {
            return nil
        }
        return DisplayCapturePlan(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            slices: slices
        )
    }
}

enum ScreenCaptureDisplayScale {
    static func resolve(
        display: SCDisplay,
        filter: SCContentFilter
    ) -> CGFloat {
        if #available(macOS 14.0, *) {
            return CGFloat(filter.pointPixelScale)
        }
        return resolve(
            pixelWidth: display.width,
            pixelHeight: display.height,
            frame: display.frame
        )
    }

    static func resolve(
        pixelWidth: Int,
        pixelHeight: Int,
        frame: CGRect
    ) -> CGFloat {
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0,
              pixelWidth > 0,
              pixelHeight > 0 else {
            return 1
        }
        let horizontal = CGFloat(pixelWidth) / frame.width
        let vertical = CGFloat(pixelHeight) / frame.height
        guard horizontal.isFinite, vertical.isFinite else { return 1 }
        return max(1, min(horizontal, vertical))
    }
}

public struct ScreenCaptureKitRegionCapturer: ScreenRegionImageCapturing {
    static let maximumPixelDimension = 65_535
    static let maximumPixelCount = 67_108_864

    public init() {}

    public func capture(quartzRect: CGRect) async throws -> CGImage {
        let quartzRect = ScreenCaptureGeometry.alignedToPointGrid(quartzRect)
        let content = try await SCShareableContent.current
        let displaysByID = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        let ownProcessID = getpid()
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ownProcessID
        }
        let displays = content.displays.map { display in
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            return CaptureDisplay(
                id: display.displayID,
                frame: display.frame,
                scale: ScreenCaptureDisplayScale.resolve(
                    display: display,
                    filter: filter
                )
            )
        }

        guard let plan = DisplayCapturePlanner.plan(for: quartzRect, displays: displays) else {
            throw ClipError.invalidSelection
        }
        guard plan.isWithinLimits(
            maxDimension: Self.maximumPixelDimension,
            maxPixelCount: Self.maximumPixelCount
        ) else {
            throw ClipError.outputTooLarge
        }

        // The common single-display path is already returned by
        // ScreenCaptureKit at the requested native pixel size. Returning it
        // directly avoids a second bitmap draw and its interpolation filter.
        if plan.slices.count == 1,
           let slice = plan.slices.first,
           let display = displaysByID[slice.displayID] {
            let image = try await Self.captureSlice(
                slice,
                display: display,
                excluding: ownWindows
            )
            if image.width == plan.pixelWidth, image.height == plan.pixelHeight {
                return image
            }
        }

        guard let context = Self.makeContext(width: plan.pixelWidth, height: plan.pixelHeight) else {
            throw ClipError.outputTooLarge
        }

        for slice in plan.slices {
            guard let display = displaysByID[slice.displayID] else {
                throw ClipError.captureFailed
            }
            let image = try await Self.captureSlice(
                slice,
                display: display,
                excluding: ownWindows
            )
            Self.draw(image, in: slice.destinationRect, canvasHeight: plan.pixelHeight, context: context)
        }

        guard let result = context.makeImage() else {
            throw ClipError.captureFailed
        }
        return result
    }

    private static func captureSlice(
        _ slice: DisplayCaptureSlice,
        display: SCDisplay,
        excluding ownWindows: [SCWindow]
    ) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = slice.sourceRect
        configuration.width = Int(ceil(slice.destinationRect.width))
        configuration.height = Int(ceil(slice.destinationRect.height))
        configuration.scalesToFit = true
        if #available(macOS 14.0, *) {
            configuration.preservesAspectRatio = true
        }
        configuration.showsCursor = false
        configuration.capturesAudio = false

        // Excluding every Clip-owned overlay keeps selection chrome and
        // annotations out of the source pixels captured at final confirmation.
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        return try await captureImage(filter: filter, configuration: configuration)
    }

    private static func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        }
        return try await LegacySingleFrameCapturer.capture(
            filter: filter,
            configuration: configuration
        )
    }

    static func makeContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    static func draw(
        _ image: CGImage,
        in topLeftRect: CGRect,
        canvasHeight: Int,
        context: CGContext
    ) {
        let drawingRect = CGRect(
            x: topLeftRect.minX,
            y: CGFloat(canvasHeight) - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        )
        // Every slice has already been produced at its destination pixel size.
        // A nearest-pixel composite preserves one-pixel window dividers and text.
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.draw(image, in: drawingRect)
    }
}

private enum LegacySingleFrameCapturer {
    static func capture(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        let output = LegacySingleFrameOutput()
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: output
        )
        try stream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: output.sampleQueue
        )
        let sendableStream = SendableLegacyStream(value: stream)

        let image = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CGImage, Error>) in
                output.install(continuation)
                stream.startCapture { error in
                    if let error {
                        output.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            output.finish(.failure(CancellationError()))
            Task.detached(priority: .utility) {
                try? await sendableStream.value.stopCapture()
            }
        }

        try? await stream.stopCapture()
        return image
    }
}

private final class LegacySingleFrameOutput: NSObject,
    SCStreamOutput,
    SCStreamDelegate,
    @unchecked Sendable
{
    let sampleQueue = DispatchQueue(
        label: "cc.clip.mac.single-frame",
        qos: .userInitiated
    )

    private let lock = NSLock()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var pendingResult: Result<CGImage, Error>?

    func install(_ continuation: CheckedContinuation<CGImage, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let frame = imageContext.createCGImage(image, from: image.extent) else {
            return
        }
        finish(.success(frame))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(.failure(error))
    }

    func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        guard pendingResult == nil else {
            lock.unlock()
            return
        }
        pendingResult = result
        lock.unlock()
    }
}

private struct SendableLegacyStream: @unchecked Sendable {
    let value: SCStream
}
