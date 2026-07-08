import Foundation

/// Applies a rename plan in two phases so in-batch name handoffs (A↔B swaps,
/// cycles) work: every clean item first moves to a unique temp name, then to
/// its final name. A phase-2 failure rolls that item back to its original
/// name so no file is ever stranded at a temp name.
public enum RenameExecutor {
    public struct Outcome: Sendable {
        public let pairs: [(from: URL, to: URL)]
        public let failures: [String]
    }

    public static func execute(_ items: [RenamePlan.Item]) -> Outcome {
        let fm = FileManager.default
        var pairs: [(from: URL, to: URL)] = []
        var failures: [String] = []

        struct Staged {
            let originalURL: URL
            let tempURL: URL
            let finalURL: URL
        }
        var staged: [Staged] = []

        // Phase 1: clean items → unique temp names in place.
        for (index, item) in items.enumerated() {
            switch item.conflict {
            case .some(.unchanged):
                continue
            case .some(let conflict):
                failures.append(
                    "“\(item.source.lastPathComponent)” skipped (\(conflict)).")
            case nil:
                let dir = item.source.deletingLastPathComponent()
                let temp = dir.appendingPathComponent(
                    ".fx-rename-\(UUID().uuidString)-\(index)")
                do {
                    try fm.moveItem(at: item.source, to: temp)
                    staged.append(Staged(
                        originalURL: item.source, tempURL: temp,
                        finalURL: dir.appendingPathComponent(item.newName)))
                } catch {
                    failures.append("Couldn't rename “\(item.source.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
        }

        // Phase 2: temp → final; on failure, roll back to the original name.
        for stage in staged {
            do {
                try fm.moveItem(at: stage.tempURL, to: stage.finalURL)
                pairs.append((from: stage.originalURL, to: stage.finalURL))
            } catch {
                failures.append("Couldn't rename “\(stage.originalURL.lastPathComponent)” to “\(stage.finalURL.lastPathComponent)”: \(error.localizedDescription)")
                try? fm.moveItem(at: stage.tempURL, to: stage.originalURL)
            }
        }
        return Outcome(pairs: pairs, failures: failures)
    }

    /// Two-phase relocation to EXACT destination URLs (possibly in other
    /// directories): every source first moves to a unique temp name in its
    /// own directory, then to its final URL. Handles swapped/cycled name
    /// sets the same way execute(_:) does; phase-2 failures roll back to
    /// the original URL.
    public static func relocate(_ moves: [(from: URL, to: URL)]) -> Outcome {
        let fm = FileManager.default
        var pairs: [(from: URL, to: URL)] = []
        var failures: [String] = []

        struct Staged {
            let originalURL: URL
            let tempURL: URL
            let finalURL: URL
        }
        var staged: [Staged] = []

        // Phase 1: every source → a unique temp name in its own directory.
        for (index, move) in moves.enumerated() {
            let dir = move.from.deletingLastPathComponent()
            let temp = dir.appendingPathComponent(
                ".fx-rename-\(UUID().uuidString)-\(index)")
            do {
                try fm.moveItem(at: move.from, to: temp)
                staged.append(Staged(
                    originalURL: move.from, tempURL: temp, finalURL: move.to))
            } catch {
                failures.append("Couldn't move “\(move.from.lastPathComponent)”: \(error.localizedDescription)")
            }
        }

        // Phase 2: temp → final; on failure, roll back to the original URL.
        for stage in staged {
            do {
                try fm.moveItem(at: stage.tempURL, to: stage.finalURL)
                pairs.append((from: stage.originalURL, to: stage.finalURL))
            } catch {
                failures.append("Couldn't move “\(stage.originalURL.lastPathComponent)” to “\(stage.finalURL.lastPathComponent)”: \(error.localizedDescription)")
                try? fm.moveItem(at: stage.tempURL, to: stage.originalURL)
            }
        }
        return Outcome(pairs: pairs, failures: failures)
    }
}
