import Foundation

public enum SpringLoad {
    public static let delay: TimeInterval = 0.7

    public static func shouldSpring(hoverStart: Date, now: Date,
                                    delay: TimeInterval = Self.delay) -> Bool {
        now.timeIntervalSince(hoverStart) >= delay
    }
}
