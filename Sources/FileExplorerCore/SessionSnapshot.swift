import Foundation

/// Serializable stand-in for one `[KeyPathComparator<FileEntry>]` element —
/// `KeyPathComparator` itself is not `Codable`.
public struct SortToken: Codable, Equatable, Sendable {
    public enum Field: String, Codable, Sendable {
        case name, size, kind, modified
    }
    public var field: Field
    public var ascending: Bool

    public init(field: Field, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }
}

public enum SortTokenCoder {
    // `PartialKeyPath` isn't `Sendable`, but this table is a fixed, immutable
    // lookup built once at first access and never mutated.
    nonisolated(unsafe) private static let fields: [(SortToken.Field, PartialKeyPath<FileEntry>)] = [
        (.name, \FileEntry.name),
        (.size, \FileEntry.size),
        (.kind, \FileEntry.kind),
        (.modified, \FileEntry.modified),
    ]

    /// Unknown key paths are dropped (a future column simply won't persist
    /// its sort until added here).
    public static func tokens(
        from comparators: [KeyPathComparator<FileEntry>]
    ) -> [SortToken] {
        comparators.compactMap { comparator in
            guard let match = fields.first(where: { $0.1 == comparator.keyPath })
            else { return nil }
            return SortToken(field: match.0,
                             ascending: comparator.order == .forward)
        }
    }

    /// Empty input restores the app-default name sort (matches
    /// `PaneState.sortOrder`'s initial value, localizedStandard comparator).
    public static func comparators(
        from tokens: [SortToken]
    ) -> [KeyPathComparator<FileEntry>] {
        let restored = tokens.map { token -> KeyPathComparator<FileEntry> in
            var comparator: KeyPathComparator<FileEntry>
            switch token.field {
            case .name:
                comparator = KeyPathComparator(\FileEntry.name,
                                               comparator: .localizedStandard)
            case .size:
                comparator = KeyPathComparator(\FileEntry.size)
            case .kind:
                comparator = KeyPathComparator(\FileEntry.kind)
            case .modified:
                comparator = KeyPathComparator(\FileEntry.modified)
            }
            comparator.order = token.ascending ? .forward : .reverse
            return comparator
        }
        return restored.isEmpty
            ? [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)]
            : restored
    }
}
