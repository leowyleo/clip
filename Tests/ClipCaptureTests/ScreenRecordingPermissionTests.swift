import ClipCore
import CoreGraphics
import Foundation
import Testing
@testable import ClipCapture

@Test func deniedPermissionStopsBeforeSystemCapture() async {
    let permission = FakePermission(isAuthorized: false)
    let capturer = FakeCapturer(result: .success(makeTestImage()))
    let service = ScreenRegionCaptureService(
        permission: permission,
        capturer: capturer,
        coordinateConverter: ScreenCoordinateConverter(mainDisplayHeight: 900)
    )

    await #expect(throws: ClipError.screenRecordingPermissionDenied) {
        try await service.capture(region: CaptureRegion(rect: CGRect(x: 10, y: 10, width: 100, height: 100)))
    }
    #expect(await capturer.receivedRects.isEmpty)
}

@Test func invalidSelectionStopsBeforePermissionCheck() async {
    let permission = FakePermission(isAuthorized: true)
    let capturer = FakeCapturer(result: .success(makeTestImage()))
    let service = ScreenRegionCaptureService(permission: permission, capturer: capturer)

    await #expect(throws: ClipError.invalidSelection) {
        try await service.capture(region: CaptureRegion(rect: CGRect(x: 0, y: 0, width: 7, height: 20)))
    }
    #expect(permission.authorizationCheckCount == 0)
    #expect(await capturer.receivedRects.isEmpty)
}

@Test func serviceConvertsAppKitSelectionBeforeCapturing() async throws {
    let expectedImage = makeTestImage(width: 4, height: 3)
    let capturer = FakeCapturer(result: .success(expectedImage))
    let service = ScreenRegionCaptureService(
        permission: FakePermission(isAuthorized: true),
        capturer: capturer,
        coordinateConverter: ScreenCoordinateConverter(mainDisplayHeight: 900)
    )

    let result = try await service.capture(
        region: CaptureRegion(rect: CGRect(x: -200, y: 650, width: 120, height: 80))
    )

    #expect(result.width == 4)
    #expect(result.height == 3)
    #expect(await capturer.receivedRects == [CGRect(x: -200, y: 170, width: 120, height: 80)])
}

@Test func servicePreservesKnownCaptureFailure() async {
    let capturer = FakeCapturer(result: .failure(ClipError.protectedContent))
    let service = ScreenRegionCaptureService(
        permission: FakePermission(isAuthorized: true),
        capturer: capturer
    )

    await #expect(throws: ClipError.protectedContent) {
        try await service.capture(region: CaptureRegion(rect: CGRect(x: 0, y: 0, width: 20, height: 20)))
    }
}

@Test func invalidNonFiniteSelectionNeverReachesSystemCapture() async {
    let permission = FakePermission(isAuthorized: true)
    let capturer = FakeCapturer(result: .success(makeTestImage()))
    let service = ScreenRegionCaptureService(permission: permission, capturer: capturer)

    await #expect(throws: ClipError.invalidSelection) {
        try await service.capture(
            region: CaptureRegion(rect: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 20))
        )
    }
    #expect(permission.authorizationCheckCount == 0)
    #expect(await capturer.receivedRects.isEmpty)
}

@Test func permissionRevokedDuringCaptureRemainsActionable() async {
    let permission = RevokedAfterPreflightPermission()
    let capturer = FakeCapturer(result: .failure(TestCaptureFailure()))
    let service = ScreenRegionCaptureService(permission: permission, capturer: capturer)

    await #expect(throws: ClipError.screenRecordingPermissionDenied) {
        try await service.capture(
            region: CaptureRegion(rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        )
    }
}

private final class FakePermission: ScreenRecordingPermissionProviding, @unchecked Sendable {
    private(set) var authorizationCheckCount = 0
    private let authorized: Bool

    init(isAuthorized: Bool) {
        authorized = isAuthorized
    }

    func isAuthorized() -> Bool {
        authorizationCheckCount += 1
        return authorized
    }

    func requestAuthorization() -> Bool {
        authorized
    }
}

private actor FakeCapturer: ScreenRegionImageCapturing {
    private(set) var receivedRects: [CGRect] = []
    private let result: Result<CGImage, Error>

    init(result: Result<CGImage, Error>) {
        self.result = result
    }

    func capture(quartzRect: CGRect) throws -> CGImage {
        receivedRects.append(quartzRect)
        return try result.get()
    }
}

private final class RevokedAfterPreflightPermission: ScreenRecordingPermissionProviding, @unchecked Sendable {
    private var checkCount = 0

    func isAuthorized() -> Bool {
        defer { checkCount += 1 }
        return checkCount == 0
    }

    func requestAuthorization() -> Bool {
        false
    }
}

private struct TestCaptureFailure: Error {}

func makeTestImage(width: Int = 1, height: Int = 1) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}
