import Foundation

public enum GitRepoLocator {
    public static func repoRoot(
        containing url: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        var current = url.standardizedFileURL
        while true {
            let gitPath = current.appendingPathComponent(".git").path
            if fileExists(gitPath) {
                return current.standardizedFileURL
            }
            let path = current.path
            guard path != "/" else { return nil }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != path else { return nil }
            current = parent
        }
    }
}
