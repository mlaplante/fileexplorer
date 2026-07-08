import Foundation

/// Pure pieces of the release check: semver-ish comparison and throttling.
/// Networking lives in the app layer (UpdateModel) — silent on failure.
public enum UpdateChecker {
    /// Numeric dotted comparison; leading "v" stripped; missing components
    /// are zero; any unparseable component makes the remote NOT newer
    /// (fail-quiet posture for a background check).
    public static func isNewer(remote: String, local: String) -> Bool {
        func components(_ raw: String) -> [Int]? {
            let trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
            let parts = trimmed.split(separator: ".").map { Int($0) }
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.compactMap { $0 }
        }
        guard let remoteParts = components(remote),
              let localParts = components(local) else { return false }
        let count = max(remoteParts.count, localParts.count)
        for index in 0..<count {
            let r = index < remoteParts.count ? remoteParts[index] : 0
            let l = index < localParts.count ? localParts[index] : 0
            if r != l { return r > l }
        }
        return false
    }

    public static let throttleInterval: TimeInterval = 24 * 3600

    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= throttleInterval
    }
}
