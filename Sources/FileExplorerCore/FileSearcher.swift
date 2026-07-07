import Foundation

public enum FileSearcher {
    /// Blocking recursive enumeration of files under `root`, hidden files and
    /// package internals skipped, result capped. Call off the main actor.
    public static func files(under root: URL, cap: Int = 50_000) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if found.count >= cap { break }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if !isDirectory { found.append(url) }
        }
        return found
    }
}
