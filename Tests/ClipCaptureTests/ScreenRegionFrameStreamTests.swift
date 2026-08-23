import ClipCore
import CoreGraphics
import Foundation
import Testing
@testable import ClipCapture

@Suite("Screen region frame streaming")
struct ScreenRegionFrameStreamTests {
    @Test func serviceConvertsSelectionAndKeepsRequestedFrameRate() async throws {
        let probe = StreamProbe()
        let service = ScreenRegionFrameStreamService(
            permission: StreamPermission(authorized: true),
            streamer: ProbeStreamer(probe: probe),
            coordinateConverter: ScreenCoordinateConverter(mainDisplayHeight: 1_000)
        )
        let region = CaptureRegion(rect: CGRect(x: 40, y: 100, width: 320, height: 240))

        let stream = try await service.stream(region: region, framesPerSecond: 30)
        let request = await probe.request
        await stream.stop()

        #expect(request?.rect == CGRect(x: 40, y: 660, width: 320, height: 240))
        #expect(request?.framesPerSecond == 30)
        #expect(await probe.didStop)
    }

    @Test func deniedPermissionNeverCreatesAStream() async {
        let probe = StreamProbe()
        let service = ScreenRegionFrameStreamService(
            permission: StreamPermission(authorized: false),
            streamer: ProbeStreamer(probe: probe),
            coordinateConverter: ScreenCoordinateConverter(mainDisplayHeight: 1_000)
        )

        await #expect(throws: ClipError.screenRecordingPermissionDenied) {
            try await service.stream(
                region: CaptureRegion(rect: CGRect(x: 0, y: 0, width: 100, height: 100))
            )
        }
        #expect(await probe.request == nil)
    }

    @Test func invalidFrameRateFailsBeforePermissionCheck() async {
        let probe = StreamProbe()
        let service = ScreenRegionFrameStreamService(
            permission: StreamPermission(authorized: true),
            streamer: ProbeStreamer(probe: probe),
            coordinateConverter: ScreenCoordinateConverter(mainDisplayHeight: 1_000)
        )

        await #expect(throws: ClipError.invalidSelection) {
            try await service.stream(
                region: CaptureRegion(rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
                framesPerSecond: 0
            )
        }
        #expect(await probe.request == nil)
    }
}

private struct StreamPermission: ScreenRecordingPermissionProviding {
    let authorized: Bool

    func isAuthorized() -> Bool { authorized }
    func requestAuthorization() -> Bool { authorized }
}

private actor StreamProbe {
    struct Request: Sendable {
        let rect: CGRect
        let framesPerSecond: Int
    }

    var request: Request?
    var didStop = false

    func record(rect: CGRect, framesPerSecond: Int) {
        request = Request(rect: rect, framesPerSecond: framesPerSecond)
    }

    func stop() {
        didStop = true
    }
}

private struct ProbeStreamer: ScreenRegionFrameStreaming {
    let probe: StreamProbe

    func stream(
        quartzRect: CGRect,
        framesPerSecond: Int
    ) async throws -> ScreenRegionFrameStream {
        await probe.record(rect: quartzRect, framesPerSecond: framesPerSecond)
        let (frames, continuation) = AsyncThrowingStream<CGImage, Error>.makeStream()
        continuation.finish()
        return ScreenRegionFrameStream(
            frames: frames,
            stopHandler: {
                await probe.stop()
            }
        )
    }
}
