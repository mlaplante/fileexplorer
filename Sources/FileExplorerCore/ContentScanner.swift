import Foundation
import UniformTypeIdentifiers

/// Deep-scan fallback for content search: streams text-like files under a
/// root through a case-insensitive substring match. Blocking — call off the
/// main actor. Bounded by entry cap and per-file size cap so a runaway tree
/// can't hang the scan.
public enum ContentScanner {
    /// Extensions treated as text when the UTType is unknown.
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "xml", "yml", "yaml", "csv",
        "swift", "js", "ts", "py", "rb", "sh", "zsh", "c", "h", "m",
        "cpp", "hpp", "css", "html", "htm", "plist", "log", "cfg",
        "conf", "ini", "toml", "sql",
    ]

    public static func isTextLike(_ type: UTType?, pathExtension: String) -> Bool {
        if let type {
            if type.conforms(to: .text) || type.conforms(to: .sourceCode)
                || type.conforms(to: .json) || type.conforms(to: .xml)
                || type.conforms(to: .propertyList) || type.conforms(to: .yaml) {
                return true
            }
            // A concrete non-text type (image, video, archive…) is rejected
            // even if its extension looks texty.
            if !type.conforms(to: .data) || type.conforms(to: .image)
                || type.conforms(to: .audiovisualContent)
                || type.conforms(to: .archive) {
                return false
            }
        }
        return textExtensions.contains(pathExtension.lowercased())
    }

    /// Recursive scan of `root` (hidden files and package internals skipped).
    /// Returns files whose contents contain `query`, case-insensitively.
    public static func scan(root: URL, query: String,
                            maxFileBytes: Int64 = 2 * 1_048_576,
                            entryCap: Int = 50_000,
                            resultCap: Int = 200) -> [URL] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var hits: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > entryCap || hits.count >= resultCap { break }
            guard let rv = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey]),
                rv.isDirectory != true,
                Int64(rv.fileSize ?? 0) <= maxFileBytes,
                isTextLike(rv.contentType, pathExtension: url.pathExtension)
            else { continue }
            guard let contents = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            else { continue }
            if contents.lowercased().contains(needle) {
                hits.append(url)
            }
        }
        return hits
    }
}
