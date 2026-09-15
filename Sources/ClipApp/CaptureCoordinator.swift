import ClipCapture
import ClipCore
import ClipScroll
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class CaptureCoordinator {
    private let captureService: ScreenRegionCaptureService
    private let frameStreamService: ScreenRegionFrameStreamService
    private let clipboardWriter: ClipboardImageWriter
    private weak var appDelegate: ClipAppDelegate?

    private var captureTask: Task<Void, Never>?
    private var finishTimeoutTask: Task<Void, Never>?
    private var captureGeneration: UInt64 = 0
    private var isFinishRequested = false
    private var activeSelectionDismiss: (() -> Void)?
    private var activeSelectionGeneration: UInt64?
    private var activeFrameStream: ScreenRegionFrameStream?
    private var activeFrameStreamGeneration: UInt64?

    init(
        appDelegate: ClipAppDelegate,
        captureService: ScreenRegionCaptureService = ScreenRegionCaptureService(),
        frameStreamService: ScreenRegionFrameStreamService = ScreenRegionFrameStreamService(),
        clipboardWriter: ClipboardImageWriter = ClipboardImageWriter()
    ) {
        self.appDelegate = appDelegate
        self.captureService = captureService
        self.frameStreamService = frameStreamService
        self.clipboardWriter = clipboardWriter

        appDelegate.onCaptureRequested = {
            [weak self] mode, region, activatePassiveFrame, dismissSelection in
            self?.start(
                mode: mode,
                region: region,
                activatePassiveFrame: activatePassiveFrame,
                dismissSelection: dismissSelection
            )
        }
        appDelegate.onCaptureCancelled = { [weak self] in
            self?.cancel()
        }
        appDelegate.onCaptureFinished = { [weak self] in
            self?.requestFinish()
        }
    }

    func start(
        mode: CaptureMode,
        region: CaptureRegion,
        activatePassiveFrame: @escaping () -> Void,
        dismissSelection: @escaping () -> Void
    ) {
        cancel(showHUDChange: captureTask != nil)
        isFinishRequested = false
        let generation = captureGeneration

        captureTask = Task { [weak self] in
            guard let self else { return }
            switch mode {
            case .region:
                if CaptureExperiencePreferences.usesEditor(for: .region) {
                    await editLiveRegion(
                        region,
                        generation: generation,
                        dismissSelection: dismissSelection
                    )
                } else {
                    dismissSelection()
                    await captureRegion(region, generation: generation)
                }
            case .scrolling:
                await captureScrolling(
                    region,
                    generation: generation,
                    activatePassiveFrame: activatePassiveFrame,
                    dismissSelection: dismissSelection
                )
            }
        }
    }

    private func editLiveRegion(
        _ region: CaptureRegion,
        generation: UInt64,
        dismissSelection: @escaping () -> Void
    ) async {
        let capturedResolution = CaptureResolutionBox()
        defer {
            dismissSelection()
            finishCaptureIfCurrent(generation)
        }
        do {
            try ensureCurrent(generation)
            guard let appDelegate else { throw CancellationError() }
            let result = try await appDelegate.editLiveCapture(
                over: region.rect,
                capture: { [captureService] finalRect in
                    let image = try await captureService.capture(
                        region: CaptureRegion(rect: finalRect)
                    )
                    await capturedResolution.set(
                        CaptureImageResolution.pixelsPerPoint(
                            pixelWidth: image.width,
                            pointWidth: finalRect.width
                        )
                    )
                    return image
                }
            )
            try ensureCurrent(generation)
            switch result {
            case .image(let image):
                let pixelsPerPoint = await capturedResolution.value
                    ?? CaptureImageResolution.pixelsPerPoint(
                        pixelWidth: image.width,
                        pointWidth: region.rect.width
                    )
                let pngData = try await encodePNG(
                    image,
                    pixelsPerPoint: pixelsPerPoint
                )
                try ensureCurrent(generation)
                try clipboardWriter.write(pngData: pngData)
                appDelegate.showCaptureCompletion()
            case .ocrTextCopied:
                appDelegate.showOCRCompletion()
            }
        } catch is CancellationError {
            if isCurrent(generation) {
                appDelegate?.hideCaptureProgress()
            }
        } catch {
            if isCurrent(generation), !Task.isCancelled {
                appDelegate?.presentCaptureError(error, retryMode: .region)
            }
        }
    }

    func cancel(showHUDChange: Bool = true) {
        captureGeneration &+= 1
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        captureTask?.cancel()
        captureTask = nil
        isFinishRequested = false
        dismissActiveSelection()
        stopActiveFrameStream()
        if showHUDChange {
            appDelegate?.hideCaptureProgress()
        }
    }

    private func requestFinish() {
        guard captureTask != nil, !isFinishRequested else { return }
        isFinishRequested = true
        dismissActiveSelection()
        stopActiveFrameStream()
        appDelegate?.showCaptureProcessing()

        let generation = captureGeneration
        finishTimeoutTask?.cancel()
        finishTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000)
            } catch {
                return
            }
            self?.finishTimedOutIfCurrent(generation)
        }
    }

    private func captureRegion(
        _ region: CaptureRegion,
        generation: UInt64
    ) async {
        defer {
            finishCaptureIfCurrent(generation)
        }
        do {
            let image = try await captureService.capture(region: region)
            try ensureCurrent(generation)
            let pngData = try await encodePNG(
                image,
                pixelsPerPoint: CaptureImageResolution.pixelsPerPoint(
                    pixelWidth: image.width,
                    pointWidth: region.rect.width
                )
            )
            try ensureCurrent(generation)
            try clipboardWriter.write(pngData: pngData)
            appDelegate?.showCaptureCompletion()
        } catch is CancellationError {
            if isCurrent(generation) {
                appDelegate?.hideCaptureProgress()
            }
        } catch {
            if isCurrent(generation), !Task.isCancelled {
                appDelegate?.presentCaptureError(error, retryMode: .region)
            }
        }
    }

    private func captureScrolling(
        _ region: CaptureRegion,
        generation: UInt64,
        activatePassiveFrame: @escaping () -> Void,
        dismissSelection: @escaping () -> Void
    ) async {
        var frameStream: ScreenRegionFrameStream?
        var processor: ContinuousScrollProcessor?
        defer {
            dismissSelection()
            clearActiveSelectionIfCurrent(generation)
            clearActiveFrameStreamIfCurrent(generation)
            finishCaptureIfCurrent(generation)
        }

        do {
            try ensureCurrent(generation)
            let stream = try await frameStreamService.stream(
                region: region,
                framesPerSecond: 30
            )
            frameStream = stream
            activeFrameStream = stream
            activeFrameStreamGeneration = generation
            var iterator = stream.frames.makeAsyncIterator()

            // The overlay still owns input until SCStream delivers its first
            // complete in-memory frame, so the starting viewport cannot race
            // with the user's first scroll gesture.
            guard let first = try await iterator.next() else {
                throw ClipError.captureFailed
            }
            try ensureCurrent(generation)
            let scrollProcessor = try ContinuousScrollProcessor()
            processor = scrollProcessor
            _ = try await scrollProcessor.ingest(first)
            let pixelsPerPoint = CaptureImageResolution.pixelsPerPoint(
                pixelWidth: first.width,
                pointWidth: region.rect.width
            )

            activeSelectionDismiss = dismissSelection
            activeSelectionGeneration = generation
            activatePassiveFrame()
            appDelegate?.showScrollingCaptureControl(near: region.rect)

            while let frame = try await iterator.next() {
                try ensureCurrent(generation)
                _ = try await scrollProcessor.ingest(frame)
            }
            guard isFinishRequested else { throw ClipError.captureFailed }

            await stream.stop()
            clearActiveFrameStreamIfCurrent(generation)
            if CaptureExperiencePreferences.usesEditor(for: .scrolling),
               let appDelegate {
                let stitched = try await withProcessingDeadline {
                    try await scrollProcessor.finalizeImage()
                }
                try ensureCurrent(generation)
                finishTimeoutTask?.cancel()
                finishTimeoutTask = nil
                appDelegate.hideCaptureProgress()

                let result = try await appDelegate.editCapture(
                    stitched.value,
                    over: region.rect,
                    replacingSelection: activeSelectionDismiss
                )
                switch result {
                case .image(let editedImage):
                    try ensureCurrent(generation)
                    let pngData = try await encodePNG(
                        editedImage,
                        pixelsPerPoint: pixelsPerPoint
                    )
                    try ensureCurrent(generation)
                    try clipboardWriter.write(pngData: pngData)
                    appDelegate.showCaptureCompletion()
                case .ocrTextCopied:
                    try ensureCurrent(generation)
                    appDelegate.showOCRCompletion()
                }
            } else {
                let completed = try await withProcessingDeadline {
                    try await scrollProcessor.finalizeAndEncode(
                        pixelsPerPoint: pixelsPerPoint
                    )
                }
                try ensureCurrent(generation)
                try clipboardWriter.write(pngData: completed.pngData)
                appDelegate?.showCaptureCompletion()
            }
        } catch is CancellationError {
            if let frameStream { await frameStream.stop() }
            if isCurrent(generation) {
                appDelegate?.hideCaptureProgress()
            }
        } catch {
            if let frameStream { await frameStream.stop() }
            if isCurrent(generation), !Task.isCancelled {
                let userFacingError = mapCaptureError(error)
                appDelegate?.presentCaptureError(
                    userFacingError,
                    retryMode: .scrolling
                )
                archiveFramesIfUseful(from: processor, after: error)
            }
        }
    }

    private func ensureCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard isCurrent(generation) else { throw CancellationError() }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        captureGeneration == generation
    }

    private func finishCaptureIfCurrent(_ generation: UInt64) {
        guard isCurrent(generation) else { return }
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        captureTask = nil
        isFinishRequested = false
    }

    private func finishTimedOutIfCurrent(_ generation: UInt64) {
        guard isCurrent(generation), captureTask != nil, isFinishRequested else {
            return
        }

        captureGeneration &+= 1
        finishTimeoutTask = nil
        captureTask?.cancel()
        captureTask = nil
        isFinishRequested = false
        dismissActiveSelection()
        stopActiveFrameStream()
        appDelegate?.presentCaptureError(
            ClipError.processingTimedOut,
            retryMode: .scrolling
        )
    }

    private func dismissActiveSelection() {
        let dismiss = activeSelectionDismiss
        activeSelectionDismiss = nil
        activeSelectionGeneration = nil
        dismiss?()
    }

    private func clearActiveSelectionIfCurrent(_ generation: UInt64) {
        guard activeSelectionGeneration == generation else { return }
        activeSelectionDismiss = nil
        activeSelectionGeneration = nil
    }

    private func stopActiveFrameStream() {
        let stream = activeFrameStream
        activeFrameStream = nil
        activeFrameStreamGeneration = nil
        guard let stream else { return }
        Task {
            await stream.stop()
        }
    }

    private func clearActiveFrameStreamIfCurrent(_ generation: UInt64) {
        guard activeFrameStreamGeneration == generation else { return }
        activeFrameStream = nil
        activeFrameStreamGeneration = nil
    }

    private func mapCaptureError(_ error: Error) -> Error {
        guard let stitchError = error as? ScrollStitchError else { return error }
        switch stitchError {
        case .noChange, .insufficientFrames:
            return ClipError.noScrollableContent
        case .changingContent:
            return ClipError.unstableContent
        case .outputTooLarge:
            return ClipError.outputTooLarge
        case .lowConfidence,
             .ambiguousOverlap,
             .noValidOverlap,
             .unexpectedScrollDirection,
             .bottomNotConfirmed:
            return ClipError.stitchConfidenceTooLow
        case .invalidConfiguration,
             .unreadableFrame,
             .frameSizeMismatch,
             .outputCreationFailed:
            return ClipError.captureFailed
        }
    }

    private func encodePNG(
        _ image: CGImage,
        pixelsPerPoint: CGFloat
    ) async throws -> Data {
        let sendableImage = SendableCGImage(value: image)
        return try await withProcessingDeadline {
            try PNGImageEncoder.encode(
                sendableImage.value,
                pixelsPerPoint: pixelsPerPoint
            )
        }
    }

    private func archiveFramesIfUseful(
        from processor: ContinuousScrollProcessor?,
        after error: Error
    ) {
        guard let processor,
              error as? ClipError != .processingTimedOut,
              !isOutputTooLarge(error) else { return }

        Task.detached(priority: .utility) {
            let frames = await processor.retainedSourceImages()
            guard !frames.isEmpty else { return }
            _ = try? FailedCaptureStore.save(frames: frames)
        }
    }

    private func isOutputTooLarge(_ error: Error) -> Bool {
        guard let stitchError = error as? ScrollStitchError else { return false }
        if case .outputTooLarge = stitchError { return true }
        return false
    }
}

private actor ContinuousScrollProcessor {
    private var session: ContinuousScrollSession

    init(configuration: ContinuousScrollConfiguration = .init()) throws {
        session = try ContinuousScrollSession(configuration: configuration)
    }

    func ingest(_ image: CGImage) throws -> ContinuousScrollProgress {
        try session.ingest(image)
    }

    func finalizeAndEncode(pixelsPerPoint: CGFloat) throws -> ScrollCompletionOutput {
        let result = try session.finalize()
        return ScrollCompletionOutput(
            pngData: try PNGImageEncoder.encode(
                result.image,
                pixelsPerPoint: pixelsPerPoint
            )
        )
    }

    func finalizeImage() throws -> SendableCGImage {
        SendableCGImage(value: try session.finalize().image)
    }

    func retainedSourceImages() -> [CGImage] {
        session.retainedSourceImages()
    }
}

private struct SendableCGImage: @unchecked Sendable {
    let value: CGImage
}

private actor CaptureResolutionBox {
    private(set) var value: CGFloat?

    func set(_ value: CGFloat) {
        self.value = value
    }
}

private struct ScrollCompletionOutput: Sendable {
    let pngData: Data
}

private enum FailedCaptureStore {
    static func save(frames: [CGImage]) throws -> URL {
        let manager = FileManager.default
        let cache = try manager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let directory = cache
            .appendingPathComponent("Clip", isDirectory: true)
            .appendingPathComponent("FailedCaptures", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        for (index, image) in frames.enumerated() {
            try Task.checkCancellation()
            let filename = String(format: "frame-%03d.png", index + 1)
            let destinationURL = directory.appendingPathComponent(filename)
            guard let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                throw ClipError.captureFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ClipError.captureFailed
            }
        }
        return directory
    }
}
