import Foundation
import FileExplorerCore

/// `Bool` isn't `Comparable`, so `KeyPathComparator(\FileEntry.isHidden)`
/// doesn't compile directly. This stand-in lets the "unmapped key path"
/// test build a comparator over `isHidden` without changing what it verifies
/// (that `SortTokenCoder` drops any key path it doesn't recognize).
private struct BoolComparator: SortComparator {
    var order: SortOrder = .forward
    func compare(_ lhs: Bool, _ rhs: Bool) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        let ascending: ComparisonResult = lhs ? .orderedDescending : .orderedAscending
        return order == .forward ? ascending
            : (ascending == .orderedAscending ? .orderedDescending : .orderedAscending)
    }
}

@MainActor
func sessionSnapshotTests() async {
    await test("FilterState round-trips through JSON") {
        var filter = FilterState()
        filter.preset = .images
        filter.extensions = ["png", "jpg"]
        filter.datePreset = .last7Days
        filter.sizePreset = .over100MB
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(FilterState.self, from: data)
        expectEqual(decoded, filter, "filter state survives encode/decode")
    }

    await test("SortTokenCoder maps comparators to tokens and back") {
        var sizeDescending = KeyPathComparator(\FileEntry.size)
        sizeDescending.order = .reverse
        let comparators = [
            KeyPathComparator(\FileEntry.name, comparator: .localizedStandard),
            sizeDescending,
        ]
        let tokens = SortTokenCoder.tokens(from: comparators)
        expectEqual(tokens, [SortToken(field: .name, ascending: true),
                             SortToken(field: .size, ascending: false)],
                    "known key paths map to tokens with direction")

        let restored = SortTokenCoder.comparators(from: tokens)
        expectEqual(restored.count, 2, "both comparators restored")
        expect(restored[0].keyPath == \FileEntry.name, "name key path restored")
        expectEqual(restored[0].order, .forward, "ascending restored")
        expect(restored[1].keyPath == \FileEntry.size, "size key path restored")
        expectEqual(restored[1].order, .reverse, "descending restored")
    }

    await test("SortTokenCoder drops unknown key paths and defaults when empty") {
        let tokens = SortTokenCoder.tokens(
            from: [KeyPathComparator(\FileEntry.isHidden, comparator: BoolComparator())])
        expect(tokens.isEmpty, "unmapped key path dropped")

        let restored = SortTokenCoder.comparators(from: [])
        expectEqual(restored.count, 1, "empty tokens restore a default sort")
        expect(restored[0].keyPath == \FileEntry.name, "default sort is by name")
    }
}
