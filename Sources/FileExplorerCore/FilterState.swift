import Foundation

public struct FilterState: Equatable, Sendable, Codable {
    public var preset: TypePreset?
    /// Lowercased extensions without leading dots, e.g. ["png", "jpg"].
    public var extensions: Set<String> = []
    public var datePreset: DatePreset?
    public var sizePreset: SizePreset?
    /// Custom ranges override the corresponding preset when set (M8).
    /// OPTIONAL by contract: synthesized Codable decodes missing keys as nil,
    /// which keeps M7-era session.json files loading.
    public var customDateRange: ClosedRange<Date>?
    public var customSizeRange: ClosedRange<Int64>?
    /// Finder-tag filter: entry passes if it carries ANY of these tags.
    /// OPTIONAL for the same forward-compat contract as the custom ranges:
    /// synthesized Codable decodes a missing key as nil, so session.json
    /// files written before M10 keep loading.
    public var tags: Set<String>?

    public init() {}

    public var isActive: Bool {
        preset != nil || !extensions.isEmpty || datePreset != nil
            || sizePreset != nil || customDateRange != nil || customSizeRange != nil
            || tags != nil
    }
}

public extension FilterState {
    /// Parses a size-popover megabyte field into bytes, clamped to a safe,
    /// non-negative band so the MB→bytes multiplication can never overflow
    /// or go negative. Empty/garbage input → 0.
    static func megabytesFieldToBytes(_ text: String) -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let megabytes = min(max(Int64(trimmed) ?? 0, 0), Int64.max / 1_048_576)
        return megabytes * 1_048_576
    }
}
