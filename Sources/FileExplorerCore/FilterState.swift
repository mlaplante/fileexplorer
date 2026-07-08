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

    public init() {}

    public var isActive: Bool {
        preset != nil || !extensions.isEmpty || datePreset != nil
            || sizePreset != nil || customDateRange != nil || customSizeRange != nil
    }
}
