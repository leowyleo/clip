import AppKit

/// The eight drag zones around a rectangular selection, named by their on-screen
/// position. Shared by the capture overlay (AppKit coordinates, y-up) and the
/// annotation canvas (flipped coordinates, y-down).
enum SelectionEdge: CaseIterable, Equatable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return true
        case .top, .bottom, .left, .right:
            return false
        }
    }

    // AppKit coordinates: origin bottom-left, y grows upward.
    var usesMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var usesMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
    var usesMinY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var usesMaxY: Bool { self == .topLeft || self == .top || self == .topRight }

    // Flipped coordinates: origin top-left, y grows downward.
    var usesMinYFlipped: Bool { usesMaxY }
    var usesMaxYFlipped: Bool { usesMinY }

    func point(in rect: CGRect, flipped: Bool) -> CGPoint {
        let x = usesMinX ? rect.minX : usesMaxX ? rect.maxX : rect.midX
        let usesMinY = flipped ? usesMinYFlipped : usesMinY
        let usesMaxY = flipped ? usesMaxYFlipped : usesMaxY
        let y = usesMinY ? rect.minY : usesMaxY ? rect.maxY : rect.midY
        return CGPoint(x: x, y: y)
    }

    @MainActor
    func cursor() -> NSCursor {
        switch self {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .topLeft, .bottomRight:
            return ResizeCursorStore.northWestSouthEast
        case .topRight, .bottomLeft:
            return ResizeCursorStore.northEastSouthWest
        }
    }

    /// Resizes `original` by moving this edge to `point`. The opposite side stays
    /// anchored. `bounds` clamps the result to a fixed area; pass `nil` to let the
    /// frame extend past it, which is how a crop can grow beyond the capture.
    func resizedRect(
        original: CGRect,
        to point: CGPoint,
        flipped: Bool,
        bounds: CGRect?,
        minimumSize: CGFloat = 8
    ) -> CGRect {
        var result = original
        let usesMinY = flipped ? usesMinYFlipped : usesMinY
        let usesMaxY = flipped ? usesMaxYFlipped : usesMaxY

        if usesMinX {
            var x = point.x
            if let bounds { x = max(x, bounds.minX) }
            x = min(x, original.maxX - minimumSize)
            result.origin.x = x
            result.size.width = original.maxX - x
        }
        if usesMaxX {
            var x = point.x
            if let bounds { x = min(x, bounds.maxX) }
            x = max(x, original.minX + minimumSize)
            result.size.width = x - original.minX
        }
        if usesMinY {
            var y = point.y
            if let bounds { y = max(y, bounds.minY) }
            y = min(y, original.maxY - minimumSize)
            result.origin.y = y
            result.size.height = original.maxY - y
        }
        if usesMaxY {
            var y = point.y
            if let bounds { y = min(y, bounds.maxY) }
            y = max(y, original.minY + minimumSize)
            result.size.height = y - original.minY
        }

        guard let bounds else {
            return result.standardized
        }
        return result.standardized.intersection(bounds)
    }

    /// Returns the drag zone at `point`, corners first. Visual top and bottom
    /// follow the coordinate system given by `flipped`. Returns `nil` when the
    /// point is neither near a border nor an edge.
    static func zone(
        at point: CGPoint,
        in rect: CGRect,
        padding: CGFloat,
        flipped: Bool
    ) -> SelectionEdge? {
        guard rect.width > 0, rect.height > 0 else { return nil }

        let visualTop = flipped ? rect.minY : rect.maxY
        let visualBottom = flipped ? rect.maxY : rect.minY
        let nearLeft = abs(point.x - rect.minX) <= padding
        let nearRight = abs(point.x - rect.maxX) <= padding
        let nearTop = abs(point.y - visualTop) <= padding
        let nearBottom = abs(point.y - visualBottom) <= padding
        // The span checks are flip-agnostic: numeric minY is always below maxY.
        let withinX = point.x >= rect.minX - padding && point.x <= rect.maxX + padding
        let withinY = point.y >= rect.minY - padding && point.y <= rect.maxY + padding

        if nearLeft, nearTop { return .topLeft }
        if nearRight, nearTop { return .topRight }
        if nearLeft, nearBottom { return .bottomLeft }
        if nearRight, nearBottom { return .bottomRight }
        if nearLeft, withinY { return .left }
        if nearRight, withinY { return .right }
        if nearTop, withinX { return .top }
        if nearBottom, withinX { return .bottom }
        return nil
    }
}

/// macOS ships no public diagonal resize cursors, so Clip draws its own in the
/// same double-arrow style as the built-in horizontal and vertical ones.
@MainActor
private enum ResizeCursorStore {
    static let northWestSouthEast = makeDiagonalCursor(topLeftToBottomRight: true)
    static let northEastSouthWest = makeDiagonalCursor(topLeftToBottomRight: false)

    private static func makeDiagonalCursor(topLeftToBottomRight: Bool) -> NSCursor {
        let side: CGFloat = 18
        let wing: CGFloat = 4.5
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            // Image coordinates have their origin at the bottom-left.
            let firstEnd: CGPoint
            let secondEnd: CGPoint
            if topLeftToBottomRight {
                firstEnd = CGPoint(x: 2.5, y: side - 2.5)   // visual top-left
                secondEnd = CGPoint(x: side - 2.5, y: 2.5)  // visual bottom-right
            } else {
                firstEnd = CGPoint(x: side - 2.5, y: side - 2.5) // visual top-right
                secondEnd = CGPoint(x: 2.5, y: 2.5)              // visual bottom-left
            }

            let path = NSBezierPath()
            path.move(to: firstEnd)
            path.line(to: secondEnd)
            for (end, inwardX, inwardY) in [
                (firstEnd, CGFloat(topLeftToBottomRight ? 1 : -1), CGFloat(-1)),
                (secondEnd, CGFloat(topLeftToBottomRight ? -1 : 1), CGFloat(1))
            ] {
                path.move(to: end)
                path.line(to: CGPoint(x: end.x + inwardX * wing, y: end.y))
                path.move(to: end)
                path.line(to: CGPoint(x: end.x, y: end.y + inwardY * wing))
            }

            path.lineWidth = 3.5
            path.lineCapStyle = .round
            NSColor.white.setStroke()
            path.stroke()
            path.lineWidth = 1.6
            NSColor.black.setStroke()
            path.stroke()
            return true
        }

        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}
