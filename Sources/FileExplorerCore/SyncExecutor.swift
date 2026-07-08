import Foundation

/// Executes a FolderComparator sync plan. Blocking — call off the main
/// actor. Overwrites trash the existing target first so undo can restore
/// it; failures are per-item and never abort the batch.
public enum SyncExecutor {
    public struct Outcome: Sendable {
        public var copied: [URL] = []
        public var trashed: [(original: URL, trashed: URL)] = []
        public var failures: [String] = []

        public init() {}
    }

    public static func execute(_ plan: [FolderComparator.SyncOperation],
                               from sourceRoot: URL, to targetRoot: URL) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        for operation in plan {
            let source = sourceRoot.appendingPathComponent(operation.relativePath)
            let target = targetRoot.appendingPathComponent(operation.relativePath)
            do {
                if operation.kind == .overwrite, fm.fileExists(atPath: target.path) {
                    let trashedURL = try FileOperationService.trashItem(target)
                    outcome.trashed.append((original: target, trashed: trashedURL))
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
                outcome.copied.append(target)
            } catch {
                outcome.failures.append(
                    "\(operation.relativePath): \(error.localizedDescription)")
            }
        }
        return outcome
    }
}
