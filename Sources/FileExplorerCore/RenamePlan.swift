import Foundation

public struct RenameRules: Equatable, Sendable {
    public var find = ""
    public var replace = ""
    public var prefix = ""
    public var suffix = ""
    public var numbering = false
    public var numberStart = 1
    public var numberPadding = 2

    public init() {}
}

/// Pure batch-rename planner: computes before→after names and flags conflicts
/// so the UI can preview safely before touching disk.
public enum RenamePlan {
    public enum Conflict: Equatable, Sendable {
        case duplicateTarget   // two items in the batch map to the same name
        case existingFile      // target name already taken in the folder
        case invalidName       // empty, "/", ".", ".."
        case unchanged         // rules produce the same name — skip on apply
    }

    public struct Item: Equatable, Sendable {
        public let source: URL
        public let newName: String
        public let conflict: Conflict?

        public init(source: URL, newName: String, conflict: Conflict?) {
            self.source = source
            self.newName = newName
            self.conflict = conflict
        }
    }

    public static func plan(urls: [URL], rules: RenameRules,
                            existingNames: Set<String>) -> [Item] {
        var counter = rules.numberStart
        let proposals: [(URL, String)] = urls.map { url in
            let ext = url.pathExtension
            var base = url.deletingPathExtension().lastPathComponent
            if !rules.find.isEmpty {
                base = base.replacingOccurrences(of: rules.find, with: rules.replace)
            }
            base = rules.prefix + base + rules.suffix
            if rules.numbering {
                let number = String(counter)
                let padded = String(repeating: "0",
                                    count: max(0, rules.numberPadding - number.count))
                    + number
                base += "-\(padded)"
                counter += 1
            }
            let newName = ext.isEmpty ? base : "\(base).\(ext)"
            return (url, newName)
        }

        var targetCounts: [String: Int] = [:]
        for (_, name) in proposals {
            targetCounts[name, default: 0] += 1
        }

        // Pre-conflicts that don't depend on which names actually vacate:
        // invalidName and duplicateTarget precede existingFile regardless of
        // in-batch handoffs, so they can be computed up front.
        var preConflicts: [Conflict?] = proposals.map { source, newName in
            if newName.isEmpty || newName.contains("/")
                || newName == "." || newName == ".." {
                return .invalidName
            } else if newName == source.lastPathComponent {
                return .unchanged
            } else if targetCounts[newName, default: 0] > 1 {
                return .duplicateTarget
            }
            return nil
        }

        // Names the batch itself is renaming away — but only from proposals
        // that are actually going to move (no pre-conflict). A target equal
        // to one of these is legal (two-phase execution makes the handoff
        // safe). Iterate to a fixpoint: marking a proposal .existingFile
        // means its source name no longer vacates, which can cascade to
        // dependents that relied on that vacancy. Removing names from
        // `vacated` only shrinks the set, so this terminates.
        var vacated = Set(zip(proposals, preConflicts)
            .filter { $0.1 == nil && $0.0.0.lastPathComponent != $0.0.1 }
            .map { $0.0.0.lastPathComponent })

        var changed = true
        while changed {
            changed = false
            for (index, proposal) in proposals.enumerated() {
                guard preConflicts[index] == nil else { continue }
                let (source, newName) = proposal
                if existingNames.contains(newName), !vacated.contains(newName) {
                    preConflicts[index] = .existingFile
                    if vacated.remove(source.lastPathComponent) != nil {
                        changed = true
                    }
                }
            }
        }

        return zip(proposals, preConflicts).map { proposal, conflict in
            Item(source: proposal.0, newName: proposal.1, conflict: conflict)
        }
    }
}
