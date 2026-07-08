import Foundation

public struct FilterState: Equatable, Sendable, Codable {
    public var preset: TypePreset?
    /// Lowercased extensions without leading dots, e.g. ["png", "jpg"].
    public var extensions: Set<String> = []
    public var datePreset: DatePreset?
    public var sizePreset: SizePreset?

    public init() {}

    public var isActive: Bool {
        preset != nil || !extensions.isEmpty || datePreset != nil || sizePreset != nil
    }
}
