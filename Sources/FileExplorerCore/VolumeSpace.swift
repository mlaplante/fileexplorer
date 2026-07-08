import Foundation

public enum VolumeSpace {
    public static func availableBytes(for url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    public static func label(bytes: Int64?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes,
                                         countStyle: .file) + " available"
    }
}
