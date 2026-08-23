import ClipCore
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public struct ScreenRegionFrameStream: Sendable {
    public let frames: AsyncThrowingStream<CGImage, Error>
    private let stopHandler: @Sendable () async -> Void

    init(
        frames: AsyncThrowingStream<CGImage, Error>,
        stopHandler: @escaping @Sendable () async -> Void
    ) {
        self.frames = frames
        self.stopHandler = stopHandler
    }

    public func stop() async {
        await stopHandler()
    }
}

public protocol ScreenRegionFrameStreaming: Sendable {
    func stream(quartzRect: CGRect, framesPerSecond: Int) async throws -> ScreenRegionFrameStream
}

public struct ScreenRegionFrameStreamService: Sendable {
    private let permission: any ScreenRecordingPermissionProviding
    private let streamer: any ScreenRegionFrameStreaming
    private let coordinateConverter: ScreenCoordinateConverter

    public init(
        permission: any ScreenRecordingPermissionProviding = SystemScreenRecordingPermission(),
        streamer: any ScreenRegionFrameStreaming = ScreenCaptureKitRegionFrameStreamer(),
        coordinateConverter: ScreenCoordinateConverter = ScreenCoordinateConverter()
    ) {
        self.permission = permission
        self.streamer = streamer
        self.coordinateConverter = coordinateConverter
    }

    public func stream(
        region: CaptureRegion,
        framesPerSecond: Int = 30
    ) async throws -> ScreenRegionFrameStream {
        guard region.isUsable,
              region.rect.origin.x.isFinite,
              region.rect.origin.y.isFinite,
              region.rect.width.isFinite,
              region.rect.height.isFinite,
              (1...60).contains(framesPerSecond) else {
            throw ClipError.invalidSelection
        }
        guard permission.isAuthorized() else {
            throw ClipError.screenRecordingPermissionDenied
        }

        let quartzRect = coordinateConverter.quartzRect(fromAppKit: region.rect)
        do {
            return try await streamer.stream(
                quartzRect: quartzRect,
                framesPerSecond: framesPerSecond
            )
        } catch let error as ClipError {
            throw error
        } catch {
            guard permission.isAuthorized() else {
                throw ClipError.screenRecordingPermissionDenied
            }
            throw ClipError.captureFailed
        }
    }
}

public struct ScreenCaptureKitRegionFrameStreamer: ScreenRegionFrameStreaming {
    public init() {}

    public func stream(
        quartzRect: CGRect,
        framesPerSecond: Int
    ) async throws -> ScreenRegionFrameStream {
        let quartzRect = quartzRect.standardized
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: {
            Self.contains(quartzRect, in: $0.frame)
        }) else {
            // A scrolling viewport must live on one physical display. Normal
            // region screenshots keep their existing cross-display support.
            throw ClipError.invalidSelection
        }

        let ownProcessID = getpid()
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ownProcessID
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let scale = CGFloat(filter.pointPixelScale)
        guard scale.isFinite, scale > 0 else { throw ClipError.captureFailed }

        let sourceRect = CGRect(
            x: quartzRect.minX - display.frame.minX,
            y: quartzRect.minY - display.frame.minY,
            width: quartzRect.width,
            height: quartzRect.height
        )
        let width = Int(ceil(sourceRect.width * scale))
        let height = Int(ceil(sourceRect.height * scale))
        guard width > 0,
              height > 0,
              width <= ScreenCaptureKitRegionCapturer.maximumPixelDimension,
              height <= ScreenCaptureKitRegionCapturer.maximumPixelDimension,
              height <= ScreenCaptureKitRegionCapturer.maximumPixelCount / width else {
            throw ClipError.outputTooLarge
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(framesPerSecond)
        )
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.showMouseClicks = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false

        let (frames, continuation) = AsyncThrowingStream<CGImage, Error>.makeStream(
            // Preserve a bounded burst when image analysis briefly trails fast
            // trackpad movement, without allowing unbounded frame memory.
            bufferingPolicy: .bufferingNewest(12)
        )
        let output = StreamFrameOutput(continuation: continuation)
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
        let session = StreamCaptureSession(stream: stream, output: output)

        do {
            try await session.start()
        } catch {
            await session.stop()
            throw error
        }

        return ScreenRegionFrameStream(
            frames: frames,
            stopHandler: {
                await session.stop()
            }
        )
    }

    private static func contains(_ rect: CGRect, in displayFrame: CGRect) -> Bool {
        let intersection = displayFrame.intersection(rect)
        guard !intersection.isNull else { return false }
        let tolerance: CGFloat = 0.5
        return intersection.width >= rect.width - tolerance
            && intersection.height >= rect.height - tolerance
    }
}

private final class StreamFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let sampleQueue = DispatchQueue(
        label: "cc.clip.mac.scroll-frames",
        qos: .userInitiated
    )

    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<CGImage, Error>.Continuation?
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    init(continuation: AsyncThrowingStream<CGImage, Error>.Continuation) {
        self.continuation = continuation
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
        guard let frame = imageContext.createCGImage(image, from: image.extent) else { return }
        currentContinuation()?.yield(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(throwing: error)
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        let activeContinuation = continuation
        continuation = nil
        lock.unlock()

        if let error {
            activeContinuation?.finish(throwing: error)
        } else {
            activeContinuation?.finish()
        }
    }

    private func currentContinuation() -> AsyncThrowingStream<CGImage, Error>.Continuation? {
        lock.lock()
        let activeContinuation = continuation
        lock.unlock()
        return activeContinuation
    }
}

private actor StreamCaptureSession {
    private let stream: SCStream
    private let output: StreamFrameOutput
    private var isStopped = false

    init(stream: SCStream, output: StreamFrameOutput) {
        self.stream = stream
        self.output = output
    }

    func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        // Finish the consumer-facing sequence synchronously. ScreenCaptureKit's
        // stop completion can be delayed indefinitely after a long stream; the
        // screenshot pipeline must not wait for that callback before composing.
        output.finish()
        let sendableStream = SendableSCStream(value: stream)
        Task.detached(priority: .utility) {
            try? await sendableStream.value.stopCapture()
        }
    }
}

private struct SendableSCStream: @unchecked Sendable {
    let value: SCStream
}
