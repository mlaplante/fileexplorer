import Foundation

public enum DirectoryLoader {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        .contentTypeKey,
    ]

    /// Synchronous, blocking load. Callers run it off the main actor.
    public static func load(_ directory: URL, includeHidden: Bool) throws -> [FileEntry] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: includeHidden ? [] : [.skipsHiddenFiles])

        return urls.compactMap { url in
            guard let rv = try? url.resourceValues(forKeys: Set(resourceKeys)) else {
                return nil
            }
            return FileEntry(
                url: url,
                name: url.lastPathComponent,
                isDirectory: rv.isDirectory ?? false,
                isHidden: rv.isHidden ?? false,
                isSymlink: rv.isSymbolicLink ?? false,
                size: Int64(rv.fileSize ?? 0),
                created: rv.creationDate,
                modified: rv.contentModificationDate ?? .distantPast,
                contentType: rv.contentType)
        }
    }
}
