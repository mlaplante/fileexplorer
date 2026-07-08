import Foundation

public enum VolumeSpace {
    public static func availableBytes(for url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let capacity = values.volumeAvailableCapacityForImportantUsage,
           capacity > 0 {
            return capacity
        }
        if let capacity = values.volumeAvailableCapacity, capacity > 0 {
            return Int64(capacity)
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: url.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    public static func label(bytes: Int64?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes,
                                         countStyle: .file) + " available"
    }
}
