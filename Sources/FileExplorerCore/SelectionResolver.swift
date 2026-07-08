import Foundation

/// Pure click-selection semantics matching NSTableView/Finder:
/// plain = replace; ⌘ = toggle; ⇧ = contiguous range from the anchor
/// unioned with the current selection. Views own gesture detection; this
/// owns the set math so it stays unit-testable.
public enum SelectionResolver {
    public static func resolve(clicked: URL, in ordered: [URL],
                               current: Set<URL>, anchor: URL?,
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
            return current.union(ordered[range])
        }
        return [clicked]
    }
}
