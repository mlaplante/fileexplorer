import Foundation

/// Blocking filesystem mutations — call off the main actor for big batches.
/// Collision policy: fail loudly, never overwrite or auto-rename (v1).
public enum FileOperationService {
    public struct ItemResult: Sendable {
        public let source: URL
        public let outcome: Result<URL, FileOpError>
    }

    public struct FileOpError: Error, Sendable, CustomStringConvertible {
        public let message: String
        public var description: String { message }

        init(_ message: String) { self.message = message }
        init(_ error: Error) { message = error.localizedDescription }
    }

    public static func move(_ sources: [URL], into destination: URL) -> [ItemResult] {
        perform(sources, into: destination) { source, target in
            try FileManager.default.moveItem(at: source, to: target)
        }
    }

    public static func copy(_ sources: [URL], into destination: URL) -> [ItemResult] {
        perform(sources, into: destination) { source, target in
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    public static func rename(_ url: URL, to newName: String) -> Result<URL, FileOpError> {
        guard !newName.contains("/"), newName != ".", newName != ".." else {
            return .failure(FileOpError("Names can't contain “/”."))
        }
        guard newName != url.lastPathComponent else {
            return .failure(FileOpError("Name is unchanged."))
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        // A case-only rename of the SAME item (e.g. "file.txt" -> "File.txt")
        // must not trip the collision guard below — `fileExists` is
        // case-insensitive on APFS, so it would always see "the target" as
        // already existing (it's the same file). Only treat it as a real
        // collision when the target is a DIFFERENT item on disk.
        let isCaseOnlyRename = url.path.lowercased() == target.path.lowercased()
        if !isCaseOnlyRename, FileManager.default.fileExists(atPath: target.path) {
            return .failure(FileOpError("“\(newName)” already exists."))
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return .success(target)
        } catch {
            return .failure(FileOpError(error))
        }
    }

    /// Moves `url` to the EXACT target path (used by undo restores, where the
    /// desired destination name is already known). Same guards as `perform`.
    public static func relocate(_ url: URL, toExactly target: URL) -> Result<URL, FileOpError> {
        let sourcePath = url.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        if targetPath == sourcePath || targetPath.hasPrefix(sourcePath + "/") {
            return .failure(FileOpError("Can't put “\(url.lastPathComponent)” inside itself."))
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .failure(FileOpError("“\(target.lastPathComponent)” already exists."))
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return .success(target)
        } catch {
            return .failure(FileOpError(error))
        }
    }

    public static func trash(_ sources: [URL]) -> [ItemResult] {
        sources.map { source in
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: source, resultingItemURL: &resulting)
                if let trashed = resulting as URL? {
                    return ItemResult(source: source, outcome: .success(trashed))
                }
                return ItemResult(source: source,
                                  outcome: .failure(FileOpError("No trash location returned.")))
            } catch {
                return ItemResult(source: source, outcome: .failure(FileOpError(error)))
            }
        }
    }

    /// Creates "untitled folder", "untitled folder 2", … and returns it.
    public static func newFolder(in directory: URL) -> Result<URL, FileOpError> {
        let fm = FileManager.default
        var name = "untitled folder"
        var counter = 1
        var target = directory.appendingPathComponent(name)
        while fm.fileExists(atPath: target.path) {
            counter += 1
            name = "untitled folder \(counter)"
            target = directory.appendingPathComponent(name)
        }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            return .success(target)
        } catch {
            return .failure(FileOpError(error))
        }
    }

    /// Creates "untitled", "untitled 2", … empty file and returns it.
    public static func newFile(in directory: URL) -> Result<URL, FileOpError> {
        let fm = FileManager.default
        let existing = Set((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
        let name = CollisionNamer.sequentialName(base: "untitled", existing: existing)
        let target = directory.appendingPathComponent(name)
        guard fm.createFile(atPath: target.path, contents: Data()) else {
            return .failure(FileOpError("Couldn't create “\(name)”."))
        }
        return .success(target)
    }

    /// Copies into `destination`, auto-renaming Finder-style ("name copy.ext")
    /// instead of failing on collisions — paste/duplicate semantics, where a
    /// collision is expected rather than an error. The folder-into-itself
    /// guard matches `perform`.
    public static func copyAvoidingCollisions(_ sources: [URL],
                                              into destination: URL) -> [ItemResult] {
        let fm = FileManager.default
        var existing = Set((try? fm.contentsOfDirectory(atPath: destination.path)) ?? [])
        return sources.map { source in
            let sourcePath = source.standardizedFileURL.path
            let destinationPath = destination.standardizedFileURL.path
            if destinationPath == sourcePath
                || destinationPath.hasPrefix(sourcePath + "/") {
                return ItemResult(source: source, outcome: .failure(FileOpError(
                    "Can't put “\(source.lastPathComponent)” inside itself.")))
            }
            let name = CollisionNamer.copyName(for: source.lastPathComponent,
                                               existing: existing)
            let target = destination.appendingPathComponent(name)
            do {
                try fm.copyItem(at: source, to: target)
                existing.insert(name)
                return ItemResult(source: source, outcome: .success(target))
            } catch {
                return ItemResult(source: source, outcome: .failure(FileOpError(error)))
            }
        }
    }

    /// Creates "name alias" symlinks next to each source. Collisions get
    /// plain Finder-style counters ("name alias 2", "name alias 3", ...).
    public static func symlink(_ sources: [URL]) -> [ItemResult] {
        let fm = FileManager.default
        return sources.map { source in
            let directory = source.deletingLastPathComponent()
            let existing = Set((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            let aliasStem = CollisionNamer.split(source.lastPathComponent).stem + " alias"
            let name = CollisionNamer.sequentialName(base: aliasStem, existing: existing)
            let target = directory.appendingPathComponent(name)
            do {
                try fm.createSymbolicLink(at: target, withDestinationURL: source)
                return ItemResult(source: source, outcome: .success(target))
            } catch {
                return ItemResult(source: source, outcome: .failure(FileOpError(error)))
            }
        }
    }

    private static func perform(_ sources: [URL], into destination: URL,
                                _ operation: (URL, URL) throws -> Void) -> [ItemResult] {
        sources.map { source in
            let sourcePath = source.standardizedFileURL.path
            let destinationPath = destination.standardizedFileURL.path
            if destinationPath == sourcePath
                || destinationPath.hasPrefix(sourcePath + "/") {
                return ItemResult(source: source, outcome: .failure(FileOpError(
                    "Can't put “\(source.lastPathComponent)” inside itself.")))
            }
            let target = destination.appendingPathComponent(source.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                return ItemResult(source: source, outcome: .failure(
                    FileOpError("“\(source.lastPathComponent)” already exists in the destination.")))
            }
            do {
                try operation(source, target)
                return ItemResult(source: source, outcome: .success(target))
            } catch {
                return ItemResult(source: source, outcome: .failure(FileOpError(error)))
            }
        }
    }
}
