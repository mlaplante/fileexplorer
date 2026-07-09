import Foundation

public enum ScriptLister {
    public static var defaultFolder: URL {
        SessionPersister.defaultDirectory
            .appendingPathComponent("Scripts", isDirectory: true)
    }

    public static func scripts(in folder: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isExecutableKey,
            .isSymbolicLinkKey,
        ]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [])
        else { return [] }

        return entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .filter(isExecutableScript)
            .sorted {
                $0.lastPathComponent.localizedStandardCompare(
                    $1.lastPathComponent) == .orderedAscending
            }
    }

    public static func ensureFolderExists(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
    }

    private static func isExecutableScript(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isExecutableKey,
            .isSymbolicLinkKey,
        ]) else { return false }

        if values.isSymbolicLink == true {
            return isExecutableRegularFile(url.resolvingSymlinksInPath())
        }

        return values.isRegularFile == true && values.isExecutable == true
    }

    private static func isExecutableRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isExecutableKey,
        ]) else { return false }

        return values.isRegularFile == true && values.isExecutable == true
    }
}
