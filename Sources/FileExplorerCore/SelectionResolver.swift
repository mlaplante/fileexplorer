import Foundation

/// Pure click-selection semantics matching Finder's icon view:
/// plain = replace; ⌘ = toggle against the live selection; ⇧ = contiguous
/// range from the anchor unioned with `baseline`, the selection as of the
/// last non-shift click. Recomputing from that pivot (rather than the live
/// selection) lets a shift-range shrink back as well as grow — e.g. click
/// f1, shift-click f5, shift-click f2 lands on {f1, f2}, not {f1...f5}.
/// This deliberately diverges from SwiftUI's `Table`, whose shift-click
/// replaces the selection outright; the grid matches Finder instead. Views
/// own gesture detection; this owns the set math so it stays unit-testable.
public enum SelectionResolver {
    public static func entries(matching selection: some Sequence<URL>,
                               in entries: [FileEntry]) -> [FileEntry] {
        let selected = Set(selection.flatMap(canonicalPaths))
        return entries.filter { !selected.isDisjoint(with: canonicalPaths($0.url)) }
    }

    public static func canonicalPath(_ url: URL) -> String {
        (url.standardizedFileURL.path as NSString).resolvingSymlinksInPath
    }

    private static func canonicalPaths(_ url: URL) -> Set<String> {
        let path = canonicalPath(url)
        var paths: Set<String> = [path]
        if path.hasPrefix("/private/tmp/") {
            paths.insert(String(path.dropFirst("/private".count)))
        } else if path.hasPrefix("/tmp/") {
            paths.insert("/private\(path)")
        } else if path == "/private/tmp" {
            paths.insert("/tmp")
        } else if path == "/tmp" {
            paths.insert("/private/tmp")
        }
        return paths
    }

    public static func resolve(clicked: URL, in ordered: [URL],
                               current: Set<URL>, baseline: Set<URL>,
                               anchor: URL?,
                               commandDown: Bool, shiftDown: Bool) -> Set<URL> {
        if commandDown {
            var next = current
            if next.contains(clicked) {
                next.remove(clicked)
            } else {
                next.insert(clicked)
            }
            return next
        }
        if shiftDown, let anchor,
           let anchorIndex = ordered.firstIndex(of: anchor),
           let clickedIndex = ordered.firstIndex(of: clicked) {
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            return baseline.union(ordered[range])
        }
        return [clicked]
    }
}
