import CoreGraphics
import Foundation

public enum GridNavigator {
    public enum Direction: Sendable {
        case up
        case down
        case left
        case right
    }

    public static func target(from current: URL?,
                              direction: Direction,
                              frames: [URL: CGRect]) -> URL? {
        guard !frames.isEmpty else { return nil }
        guard let current, let currentFrame = frames[current] else {
            return frames.min { lhs, rhs in
                if lhs.value.midY == rhs.value.midY {
                    return lhs.value.midX < rhs.value.midX
                }
                return lhs.value.midY < rhs.value.midY
            }?.key
        }

        switch direction {
        case .left, .right:
            return horizontalTarget(from: currentFrame, direction: direction,
                                    frames: frames)
        case .up, .down:
            return verticalTarget(from: currentFrame, direction: direction,
                                  frames: frames)
        }
    }

    private static func horizontalTarget(from currentFrame: CGRect,
                                         direction: Direction,
                                         frames: [URL: CGRect]) -> URL? {
        let rowTolerance = currentFrame.height / 2
        let candidates = frames.filter { _, frame in
            abs(frame.midY - currentFrame.midY) <= rowTolerance
                && (direction == .right
                    ? frame.midX > currentFrame.midX
                    : frame.midX < currentFrame.midX)
        }
        return candidates.min { lhs, rhs in
            abs(lhs.value.midX - currentFrame.midX)
                < abs(rhs.value.midX - currentFrame.midX)
        }?.key
    }

    private static func verticalTarget(from currentFrame: CGRect,
                                       direction: Direction,
                                       frames: [URL: CGRect]) -> URL? {
        let rowThreshold = currentFrame.height / 2
        let candidates = frames.filter { _, frame in
            direction == .down
                ? frame.midY > currentFrame.midY + rowThreshold
                : frame.midY < currentFrame.midY - rowThreshold
        }
        return candidates.min { lhs, rhs in
            let lhsY = abs(lhs.value.midY - currentFrame.midY)
            let rhsY = abs(rhs.value.midY - currentFrame.midY)
            if lhsY != rhsY { return lhsY < rhsY }
            let lhsX = abs(lhs.value.midX - currentFrame.midX)
            let rhsX = abs(rhs.value.midX - currentFrame.midX)
            if lhsX != rhsX { return lhsX < rhsX }
            return lhs.value.midX < rhs.value.midX
        }?.key
    }
}
