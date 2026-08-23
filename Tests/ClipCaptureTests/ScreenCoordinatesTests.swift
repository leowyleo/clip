import CoreGraphics
import Testing
@testable import ClipCapture

@Test func venturaDerivesRetinaScaleFromDisplayPixels() {
    #expect(
        ScreenCaptureDisplayScale.resolve(
            pixelWidth: 5_120,
            pixelHeight: 2_880,
            frame: CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
        ) == 2
    )
    #expect(
        ScreenCaptureDisplayScale.resolve(
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        ) == 1
    )
}

@Test func convertsAcrossDisplaysUsingMainDisplayAxis() {
    let converter = ScreenCoordinateConverter(mainDisplayHeight: 1080)

    #expect(
        converter.quartzRect(fromAppKit: CGRect(x: -1280, y: 100, width: 300, height: 200))
            == CGRect(x: -1280, y: 780, width: 300, height: 200)
    )
    #expect(
        converter.quartzRect(fromAppKit: CGRect(x: 200, y: 1100, width: 100, height: 100))
            == CGRect(x: 200, y: -120, width: 100, height: 100)
    )
}

@Test func fixedMainDisplayHeightCanBeUpdatedWithoutRecreatingConverter() {
    var converter = ScreenCoordinateConverter(mainDisplayHeight: 900)
    #expect(
        converter.quartzRect(fromAppKit: CGRect(x: 0, y: 100, width: 20, height: 20)).minY == 780
    )

    converter.mainDisplayHeight = 1_080

    #expect(
        converter.quartzRect(fromAppKit: CGRect(x: 0, y: 100, width: 20, height: 20)).minY == 960
    )
}

@Test func capturePlanSplitsSelectionIntoDisplayLocalCoordinates() throws {
    let displays = [
        CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2),
        CaptureDisplay(id: 2, frame: CGRect(x: 1440, y: 120, width: 1920, height: 1080), scale: 1)
    ]

    let plan = try #require(
        DisplayCapturePlanner.plan(
            for: CGRect(x: 1380, y: 80, width: 180, height: 240),
            displays: displays
        )
    )

    #expect(plan.pixelWidth == 360)
    #expect(plan.pixelHeight == 480)
    #expect(plan.slices == [
        DisplayCaptureSlice(
            displayID: 1,
            sourceRect: CGRect(x: 1380, y: 80, width: 60, height: 240),
            destinationRect: CGRect(x: 0, y: 0, width: 120, height: 480)
        ),
        DisplayCaptureSlice(
            displayID: 2,
            sourceRect: CGRect(x: 0, y: 0, width: 120, height: 200),
            destinationRect: CGRect(x: 120, y: 80, width: 240, height: 400)
        )
    ])
}

@Test func capturePlanRejectsSelectionOutsideAllDisplays() {
    let displays = [CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)]

    #expect(
        DisplayCapturePlanner.plan(
            for: CGRect(x: 200, y: 200, width: 20, height: 20),
            displays: displays
        ) == nil
    )
}

@Test func retinaHalfPointSelectionIsNotExpandedToWholePoints() throws {
    let displays = [
        CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
    ]

    let plan = try #require(
        DisplayCapturePlanner.plan(
            for: CGRect(x: 10.5, y: 20.5, width: 20, height: 10),
            displays: displays
        )
    )

    #expect(plan.pixelWidth == 40)
    #expect(plan.pixelHeight == 20)
    #expect(plan.slices.first?.sourceRect == CGRect(x: 10.5, y: 20.5, width: 20, height: 10))
}

@Test func touchingRetinaDisplayDoesNotUpscaleStandardDisplaySelection() throws {
    let displays = [
        CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1),
        CaptureDisplay(id: 2, frame: CGRect(x: 100, y: 0, width: 100, height: 100), scale: 2)
    ]

    let plan = try #require(
        DisplayCapturePlanner.plan(
            for: CGRect(x: 20, y: 20, width: 80, height: 40),
            displays: displays
        )
    )

    #expect(plan.pixelWidth == 80)
    #expect(plan.pixelHeight == 40)
    #expect(plan.slices.map(\.displayID) == [1])
}

@Test func capturePlanEnforcesPixelMemoryLimitWithoutOverflow() {
    let acceptable = DisplayCapturePlan(pixelWidth: 8_192, pixelHeight: 8_192, slices: [])
    let tooManyPixels = DisplayCapturePlan(pixelWidth: 16_384, pixelHeight: 8_192, slices: [])
    let tooWide = DisplayCapturePlan(pixelWidth: 65_536, pixelHeight: 1, slices: [])

    #expect(acceptable.isWithinLimits(maxDimension: 65_535, maxPixelCount: 67_108_864))
    #expect(!tooManyPixels.isWithinLimits(maxDimension: 65_535, maxPixelCount: 67_108_864))
    #expect(!tooWide.isWithinLimits(maxDimension: 65_535, maxPixelCount: 67_108_864))
}

@Test func capturePlanRejectsNonFiniteInputsWithoutIntegerTrap() {
    let displays = [
        CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
    ]
    let extremeScaleDisplays = [
        CaptureDisplay(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: CGFloat.greatestFiniteMagnitude
        )
    ]

    #expect(
        DisplayCapturePlanner.plan(
            for: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 20),
            displays: displays
        ) == nil
    )
    #expect(
        DisplayCapturePlanner.plan(
            for: CGRect(x: 0, y: 0, width: 20, height: 20),
            displays: extremeScaleDisplays
        ) == nil
    )
}
