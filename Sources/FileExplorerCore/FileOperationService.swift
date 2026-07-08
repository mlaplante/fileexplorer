import Foundation

/// Blocking filesystem mutations — call off the main actor for big batches.
/// Collision policy: fail loudly, never overwrite or auto-rename (v1).
public enum FileOperationService {
    public struct ItemResult: Sendable {
        public let source: URL
        public let outcome: Result<URL, FileOpError>
    }

    public struct PlannedOutcome: Sendable {
        public var written: [(source: URL, destination: URL)] = []
        public var replacedTrash: [(original: URL, trashed: URL)] = []
        public var skipped: [URL] = []
        public var failures: [String] = []

        public init() {}

        public var created: [URL] {
            written.map(\.destination)
        }

        public var succeeded: Bool {
            failures.isEmpty
        }
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

    /// Executes a previously reviewed operation plan. Conflicts left in the
    /// plan are reported as failures; only `.replace` overwrites, and it first
    /// moves the existing destination to Trash so callers can register undo.
    public static func execute(_ plan: OperationConflictPlanner.Plan)
        -> PlannedOutcome {
        let fm = FileManager.default
        var outcome = PlannedOutcome()
        for item in plan.items {
            switch item.action {
            case .write(let target):
                write(item.source, to: target, operation: plan.operation,
                      outcome: &outcome)
            case .replace(let existing):
                if fm.fileExists(atPath: existing.path) {
                    do {
                        let trashed = try trashItem(existing)
                        outcome.replacedTrash.append((original: existing,
                                                      trashed: trashed))
                    } catch {
                        outcome.failures.append(
                            "\(existing.lastPathComponent): \(error.localizedDescription)")
                        continue
                    }
                }
                write(item.source, to: existing, operation: plan.operation,
                      outcome: &outcome)
            case .skip:
                outcome.skipped.append(item.source)
            case .conflict(let existing):
                outcome.failures.append(
                    "“\(existing.lastPathComponent)” already exists in the destination.")
            case .fail(let message):
                outcome.failures.append(message)
            }
        }
        return outcome
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
            do {
                return ItemResult(source: source, outcome: .success(try trashItem(source)))
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

    public enum AliasKind: Sendable {
        case symlink
        case bookmarkFile
    }

    /// Creates "name alias" symlinks next to each source. Collisions get
    /// plain Finder-style counters ("name alias 2", "name alias 3", ...).
    public static func symlink(_ sources: [URL]) -> [ItemResult] {
        makeAlias(sources, kind: .symlink)
    }

    public static func makeAlias(_ sources: [URL],
                                 kind: AliasKind) -> [ItemResult] {
        let fm = FileManager.default
        return sources.map { source in
            let directory = source.deletingLastPathComponent()
            let existing = Set((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            let aliasStem = CollisionNamer.split(source.lastPathComponent).stem + " alias"
            let name = CollisionNamer.sequentialName(base: aliasStem, existing: existing)
            let target = directory.appendingPathComponent(name)
            do {
                switch kind {
                case .symlink:
                    try fm.createSymbolicLink(at: target, withDestinationURL: source)
                case .bookmarkFile:
                    let data = try source.bookmarkData(
                        options: [.suitableForBookmarkFile],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil)
                    try URL.writeBookmarkData(data, to: target)
                }
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

    private static func write(_ source: URL, to target: URL,
                              operation: OperationConflictPlanner.Operation,
                              outcome: inout PlannedOutcome) {
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            switch operation {
            case .copy, .sync:
                try FileManager.default.copyItem(at: source, to: target)
            case .move:
                try FileManager.default.moveItem(at: source, to: target)
            }
            outcome.written.append((source: source, destination: target))
        } catch {
            outcome.failures.append(
                "\(source.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func trashItem(_ source: URL) throws -> URL {
        let fm = FileManager.default
        do {
            var resulting: NSURL?
            try fm.trashItem(at: source, resultingItemURL: &resulting)
            guard let trashed = resulting as URL? else {
                throw FileOpError("No trash location returned.")
            }
            return trashed
        } catch {
            // FileManager.trashItem can be denied under command-line
            // sandboxing even inside writable temporary directories (agent
            // test runs). Only there is a sibling .Trash an acceptable
            // stand-in — for real user paths the failure must surface rather
            // than silently diverting files to a hidden folder the system
            // Trash won't show.
            let tmp = fm.temporaryDirectory.resolvingSymlinksInPath().path + "/"
            guard source.resolvingSymlinksInPath().path.hasPrefix(tmp) else {
                throw error
            }
            let trash = source.deletingLastPathComponent().appendingPathComponent(
                ".Trash", isDirectory: true)
            try fm.createDirectory(at: trash, withIntermediateDirectories: true)
            let existing = Set((try? fm.contentsOfDirectory(atPath: trash.path)) ?? [])
            let name = CollisionNamer.sequentialName(base: source.lastPathComponent,
                                                     existing: existing)
            let target = trash.appendingPathComponent(name)
            try fm.moveItem(at: source, to: target)
            return target
        }
    }
}
