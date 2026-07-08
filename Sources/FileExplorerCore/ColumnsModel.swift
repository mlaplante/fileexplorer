import Foundation
import Observation

/// Backs the Miller-column browser: one loaded listing per visible column.
/// Ancestor columns are plain name-sorted listings; the CURRENT column is
/// rendered from the pane's own visibleEntries (filters/sort apply there),
/// so this model's last column is used only for its URL identity.
@MainActor
@Observable
public final class ColumnsModel {
    public struct Column: Identifiable, Sendable {
        public let url: URL
        public let entries: [FileEntry]
        public var id: String { url.path }
    }

    public private(set) var columns: [Column] = []
    private var generation = 0

    public init() {}

    /// The trailing `maxColumns` levels of the path, root-bounded, ending
    /// at `url` itself. Pure.
    public static func columnChain(for url: URL, maxColumns: Int) -> [URL] {
        let chain = url.standardizedFileURL.ancestorChain
        return Array(chain.suffix(maxColumns))
    }

    public func refresh(for url: URL, showHidden: Bool,
                        maxColumns: Int = 4) async {
        generation += 1
        let myGeneration = generation
        let chain = Self.columnChain(for: url, maxColumns: maxColumns)
        let loaded = await Task.detached(priority: .userInitiated) {
            chain.map { columnURL in
                Column(url: columnURL,
                       entries: (try? DirectoryLoader.load(
                           columnURL, includeHidden: showHidden)) ?? [])
            }
        }.value
        guard myGeneration == generation else { return }
        columns = loaded
    }
}
