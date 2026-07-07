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

    public var isNoOp: Bool {
        find.isEmpty && prefix.isEmpty && suffix.isEmpty && !numbering
    }
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

        return proposals.map { source, newName in
            let conflict: Conflict?
            if newName.isEmpty || newName.contains("/")
                || newName == "." || newName == ".." {
                conflict = .invalidName
            } else if newName == source.lastPathComponent {
                conflict = .unchanged
            } else if targetCounts[newName, default: 0] > 1 {
                conflict = .duplicateTarget
            } else if existingNames.contains(newName) {
                conflict = .existingFile
            } else {
                conflict = nil
            }
            return Item(source: source, newName: newName, conflict: conflict)
        }
    }
}
