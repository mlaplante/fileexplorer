import Foundation

/// Extracts zip/tar archives into a new collision-suffixed folder next to
/// the archive, via /usr/bin/ditto (zip) and /usr/bin/tar (tarballs, which
/// auto-detect their compression). Blocking — call off the main actor.
/// Failure cleans up the partial output folder.
public enum Unarchiver {
    public static func extract(_ archive: URL)
        -> Result<URL, FileOperationService.FileOpError> {
        guard let kind = ArchiveKind.detect(archive.lastPathComponent) else {
            return .failure(.init(
                "“\(archive.lastPathComponent)” isn't a supported archive."))
        }
        let fm = FileManager.default
        let parent = archive.deletingLastPathComponent()
        let existing = Set((try? fm.contentsOfDirectory(atPath: parent.path)) ?? [])
        let folderName = CollisionNamer.sequentialName(
            base: ArchiveKind.stem(archive.lastPathComponent), existing: existing)
        let destination = parent.appendingPathComponent(folderName)
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        } catch {
            return .failure(.init(error))
        }

        let process = Process()
        switch kind {
        case .zip:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, destination.path]
        case .tarball:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", archive.path, "-C", destination.path]
        }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? fm.removeItem(at: destination)
            return .failure(.init(error))
        }
        guard process.terminationStatus == 0 else {
            let stderr = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? ""
            try? fm.removeItem(at: destination)
            return .failure(.init("Extraction failed: \(stderr.prefix(200))"))
        }
        return .success(destination)
    }
}
