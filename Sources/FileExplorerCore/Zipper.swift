import Foundation

/// Compresses items into "Archive.zip" (uniquified) in `directory` using
/// /usr/bin/zip with relative paths. Blocking — call off the main actor.
public enum Zipper {
    public static func compress(_ sources: [URL], in directory: URL)
        -> Result<URL, FileOperationService.FileOpError> {
        guard !sources.isEmpty else { return .failure(.init("Nothing selected.")) }
        let fm = FileManager.default
        var name = "Archive.zip"
        var counter = 1
        var archive = directory.appendingPathComponent(name)
        while fm.fileExists(atPath: archive.path) {
            counter += 1
            name = "Archive \(counter).zip"
            archive = directory.appendingPathComponent(name)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-r", "-q", archive.path, "--"]
            + sources.map { source in
                source.path.hasPrefix(directory.path + "/")
                    ? String(source.path.dropFirst(directory.path.count + 1))
                    : source.path
            }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(.init(error))
        }
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            try? fm.removeItem(at: archive)
            return .failure(.init("zip failed: \(stderr.prefix(200))"))
        }
        return .success(archive)
    }
}
