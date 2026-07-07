import Foundation

public enum FolderScanner {
    /// Blocking BFS of subdirectories up to `maxDepth` levels below `root`,
    /// hidden dirs skipped, result capped. Call off the main actor.
    public static func subfolders(of root: URL, maxDepth: Int = 3,
                                  cap: Int = 2000) -> [URL] {
        var found: [URL] = []
        var queue: [(URL, Int)] = [(root, 0)]
        let keys: [URLResourceKey] = [.isDirectoryKey]
        while !queue.isEmpty && found.count < cap {
            let (dir, depth) = queue.removeFirst()
            guard depth < maxDepth else { continue }
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]) else { continue }
            for child in children where found.count < cap {
                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    found.append(child)
                    queue.append((child, depth + 1))
                }
            }
        }
        return found
    }
}
