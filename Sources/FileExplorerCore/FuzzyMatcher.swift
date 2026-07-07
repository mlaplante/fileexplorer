import Foundation

/// Pre-lowercased candidate for hot ranking paths (palette re-ranks per
/// keystroke over up to 50k items; preparing once avoids re-allocating
/// character arrays on every keystroke).
public struct FuzzyCandidate: Sendable {
    let lower: [Character]
    let original: [Character]

    public init(_ string: String) {
        original = Array(string)
        lower = Array(string.lowercased())
    }
}

/// Shared fuzzy scorer for the ⌘G/⌘P/⇧⌘A palettes.
public enum FuzzyMatcher {
    /// Case-insensitive subsequence score; nil when `query` is not a
    /// subsequence of `candidate`. Bonuses: candidate prefix, word/camelCase
    /// starts, consecutive runs. Mild penalty for long candidates.
    public static func score(query: String, candidate: String) -> Int? {
        score(queryLowercased: Array(query.lowercased()),
              candidate: FuzzyCandidate(candidate))
    }

    /// Same scoring algorithm as `score(query:candidate:)`, but takes a
    /// pre-lowercased query and a prepared `FuzzyCandidate` to avoid
    /// re-lowercasing the candidate on every call (hot path for re-ranking
    /// large item lists per keystroke).
    public static func score(queryLowercased q: [Character],
                             candidate: FuzzyCandidate) -> Int? {
        if q.isEmpty { return 0 }
        let lower = candidate.lower
        let original = candidate.original
        var qi = 0
        var total = 0
        var streak = 0
        var previousWasSeparator = true

        for i in 0..<lower.count {
            let isBoundary = previousWasSeparator || original[i].isUppercase
            previousWasSeparator = !lower[i].isLetter && !lower[i].isNumber
            guard qi < q.count else { break }
            if lower[i] == q[qi] {
                qi += 1
                streak += 1
                total += 1 + streak * 3
                if isBoundary { total += 4 }
                if i == 0 { total += 10 }
            } else {
                streak = 0
            }
        }
        guard qi == q.count else { return nil }
        return total - lower.count / 4
    }

    /// Filters to matches and sorts best-first; ties keep source order.
    /// Empty query returns `items` unchanged.
    public static func rank<T>(_ items: [T], query: String,
                               key: (T) -> String) -> [T] {
        guard !query.isEmpty else { return items }
        var scored: [(index: Int, item: T, score: Int)] = []
        for (index, item) in items.enumerated() {
            if let itemScore = score(query: query, candidate: key(item)) {
                scored.append((index, item, itemScore))
            }
        }
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
        }
        return scored.map { $0.item }
    }
}
