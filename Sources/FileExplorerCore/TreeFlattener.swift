import Foundation

/// Turns the list view's root entries plus lazily loaded children into the
/// ordered, depth-annotated row list the table renders.
///
/// Pure: filter/sort are injected via `prepare`, applied independently at
/// every level. A folder contributes children only when its key (standardized
/// path — trailing-slash-insensitive, unlike URL equality) is in `expanded`
/// AND `children` holds a loaded list for it — an expanded folder whose load
/// hasn't landed yet renders collapsed until it does.
public enum TreeFlattener {
    public struct Row: Equatable, Sendable {
        public let entry: FileEntry
        public let depth: Int
        public init(entry: FileEntry, depth: Int) {
            self.entry = entry
            self.depth = depth
        }
    }

    /// Hard stop for pathological nesting and symlink loops that survive
    /// the ancestor-stack check by minting ever-new paths.
    public static let maxDepth = 32

    public static func flatten(
        roots: [FileEntry],
        children: [String: [FileEntry]],
        expanded: Set<String>,
        prepare: ([FileEntry]) -> [FileEntry]
    ) -> [Row] {
        var rows: [Row] = []
        // Symlink-resolved ancestor paths; a child resolving onto one of
        // these is a cycle and must not recurse.
        var stack: Set<String> = []

        func walk(_ level: [FileEntry], depth: Int) {
            for entry in prepare(level) {
                let resolved = entry.url.resolvingSymlinksInPath().path
                guard !entry.isDirectory || !stack.contains(resolved) else {
                    continue
                }
                rows.append(Row(entry: entry, depth: depth))
                let key = entry.url.standardizedFileURL.path
                guard entry.isDirectory,
                      depth < maxDepth,
                      expanded.contains(key),
                      let kids = children[key] else { continue }
                stack.insert(resolved)
                walk(kids, depth: depth + 1)
                stack.remove(resolved)
            }
        }
        walk(roots, depth: 0)
        return rows
    }
}
