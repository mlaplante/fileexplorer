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
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard newName != url.lastPathComponent else {
            return .failure(FileOpError("Name is unchanged."))
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .failure(FileOpError("“\(newName)” already exists."))
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

    private static func perform(_ sources: [URL], into destination: URL,
                                _ operation: (URL, URL) throws -> Void) -> [ItemResult] {
        sources.map { source in
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
