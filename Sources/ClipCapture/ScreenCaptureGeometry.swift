import CoreGraphics

/// Geometry shared by still and scrolling ScreenCaptureKit entry points.
///
/// A fractional source origin makes ScreenCaptureKit resample the complete
/// frame. Aligning each edge independently preserves the user's intended
/// desktop rectangle while keeping source pixels on the display point grid.
public enum ScreenCaptureGeometry {
    public static func alignedToPointGrid(_ rect: CGRect) -> CGRect {
        let rect = rect.standardized
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite else { return rect }

        let minX = rect.minX.rounded(.toNearestOrAwayFromZero)
        let minY = rect.minY.rounded(.toNearestOrAwayFromZero)
        let maxX = rect.maxX.rounded(.toNearestOrAwayFromZero)
        let maxY = rect.maxY.rounded(.toNearestOrAwayFromZero)
        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }
}
