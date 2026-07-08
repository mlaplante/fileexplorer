import Foundation

public enum FilterEngine {
    /// Applies all active filters with AND semantics. Folders always pass so
    /// navigation stays possible while filtering. `now` anchors date presets
    /// (injectable for tests).
    public static func apply(_ filter: FilterState, to entries: [FileEntry],
                             now: Date = Date()) -> [FileEntry] {
        guard filter.isActive else { return entries }
        let dateRange = filter.customDateRange ?? filter.datePreset?.range(now: now)
        let sizeRange = filter.customSizeRange ?? filter.sizePreset?.range
        return entries.filter { entry in
            if entry.isDirectory { return true }
            if let preset = filter.preset, !preset.matches(entry.contentType) {
                return false
            }
            if !filter.extensions.isEmpty,
               !filter.extensions.contains(entry.url.pathExtension.lowercased()) {
                return false
            }
            if let dateRange, !dateRange.contains(entry.modified) {
                return false
            }
            if let sizeRange, !sizeRange.contains(entry.size) {
                return false
            }
            if let tags = filter.tags,
               entry.tags.allSatisfy({ !tags.contains($0) }) {
                return false
            }
            return true
        }
    }
}
