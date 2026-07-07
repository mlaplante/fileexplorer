import Foundation

public enum DirectoryLoader {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        .contentTypeKey,
    ]
    private static let resourceKeySet = Set(resourceKeys)

    /// Synchronous, blocking load. Callers run it off the main actor.
    ///
    /// Entries whose attributes can't be read are dropped from the result.
    /// That is deliberate: the common cause is a file deleted between the
    /// directory listing and the per-entry attribute read (TOCTOU), where
    /// dropping is correct. It also means an ACL-restricted entry can vanish
    /// from a listing rather than error the whole load.
    public static func load(_ directory: URL, includeHidden: Bool) throws -> [FileEntry] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: includeHidden ? [] : [.skipsHiddenFiles])

        return urls.compactMap { url in
            guard let rv = try? url.resourceValues(forKeys: resourceKeySet) else {
                return nil
            }
            let isSymlink = rv.isSymbolicLink ?? false
            var isDirectory = rv.isDirectory ?? false
            if isSymlink && !isDirectory {
                // resourceValues is lstat-like; follow the link (Finder-like
                // navigation) to learn whether the target is a directory.
                var targetIsDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &targetIsDir) {
                    isDirectory = targetIsDir.boolValue
                }
            }
            return FileEntry(
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDirectory,
                isHidden: rv.isHidden ?? false,
                isSymlink: isSymlink,
                size: Int64(rv.fileSize ?? 0),
                created: rv.creationDate,
                modified: rv.contentModificationDate ?? .distantPast,
                contentType: rv.contentType)
        }
    }
}
