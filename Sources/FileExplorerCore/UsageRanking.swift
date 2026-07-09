import Foundation

public struct UsageRow: Equatable, Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let bytes: Int64
    public let itemCount: Int
    public let proportion: Double

    public var id: URL { url }

    public init(url: URL, name: String, isDirectory: Bool, bytes: Int64,
                itemCount: Int, proportion: Double) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.bytes = bytes
        self.itemCount = itemCount
        self.proportion = proportion
    }
}

public enum UsageRanking {
    public static func rows(
        childTotals: [URL: (bytes: Int64, items: Int, isDirectory: Bool)]
    ) -> [UsageRow] {
        let maxBytes = childTotals.values.map(\.bytes).max() ?? 0
        return childTotals
            .map { url, total in
                UsageRow(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: total.isDirectory,
                    bytes: total.bytes,
                    itemCount: total.items,
                    proportion: maxBytes > 0 ? Double(total.bytes) / Double(maxBytes) : 0)
            }
            .sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    public static func subtracting(_ url: URL, bytes: Int64,
                                   from rows: [UsageRow]) -> [UsageRow] {
        let target = url.standardizedFileURL
        let totals: [URL: (bytes: Int64, items: Int, isDirectory: Bool)] =
            Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard row.url.standardizedFileURL != target else { return nil }
                return (row.url, (bytes: row.bytes, items: row.itemCount,
                                  isDirectory: row.isDirectory))
            })
        return self.rows(childTotals: totals)
    }
}
