import Foundation

/// A named, recallable FilterState. Identity is the name: saving under an
/// existing name replaces that preset.
public struct FilterPreset: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var filter: FilterState

    public var id: String { name }

    public init(name: String, filter: FilterState) {
        self.name = name
        self.filter = filter
    }
}
