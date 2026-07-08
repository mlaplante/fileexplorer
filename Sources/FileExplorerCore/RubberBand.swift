import Foundation

/// Pure rubber-band selection math; the grid owns gesture + frame tracking.
public enum RubberBand {
    public static func normalizedRect(from origin: CGPoint,
                                      to current: CGPoint) -> CGRect {
        CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
               width: abs(current.x - origin.x),
               height: abs(current.y - origin.y))
    }

    public static func select(frames: [URL: CGRect], rect: CGRect,
                              base: Set<URL>, union: Bool) -> Set<URL> {
        let hit = Set(frames.filter { $0.value.intersects(rect) }.keys)
        return union ? base.union(hit) : hit
    }
}
