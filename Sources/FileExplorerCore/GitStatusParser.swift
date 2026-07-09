import Foundation

public enum GitFileState: Int, Comparable, Sendable {
    case clean = 0
    case ignored = 1
    case untracked = 2
    case modified = 3
    case staged = 4
    case conflicted = 5

    public static func < (l: Self, r: Self) -> Bool {
        l.rawValue < r.rawValue
    }
}

public struct GitRepoStatus: Equatable, Sendable {
    public var branch: String?
    public var detachedOID: String?
    public var states: [String: GitFileState]
    public var ignored: Set<String>
    public var changedCount: Int

    public init(
        branch: String? = nil,
        detachedOID: String? = nil,
        states: [String: GitFileState] = [:],
        ignored: Set<String> = []
    ) {
        self.branch = branch
        self.detachedOID = detachedOID
        self.states = states
        self.ignored = ignored
        self.changedCount = states.count
    }
}

public enum GitStatusParser {
    public static let outputCap = 2 * 1024 * 1024

    public static func parse(_ data: Data) -> GitRepoStatus {
        let capped = completeRecordData(from: data)
        let records = capped.split(separator: 0).compactMap { bytes in
            String(data: Data(bytes), encoding: .utf8)
        }

        var branch: String?
        var detachedOID: String?
        var states: [String: GitFileState] = [:]
        var ignored = Set<String>()
        var skipNextRenameSource = false

        for record in records {
            if skipNextRenameSource {
                skipNextRenameSource = false
                continue
            }
            if record.hasPrefix("# ") {
                parseHeader(record, branch: &branch, detachedOID: &detachedOID)
                continue
            }

            if record.hasPrefix("1 ") {
                parseOrdinary(record, into: &states)
            } else if record.hasPrefix("2 ") {
                parseRename(record, into: &states)
                skipNextRenameSource = true
            } else if record.hasPrefix("u ") {
                if let path = pathField(record, maxSplits: 10) {
                    states[path] = .conflicted
                }
            } else if record.hasPrefix("? ") {
                let path = String(record.dropFirst(2))
                states[path] = .untracked
            } else if record.hasPrefix("! ") {
                ignored.insert(String(record.dropFirst(2)))
            }
        }

        return GitRepoStatus(
            branch: branch,
            detachedOID: detachedOID,
            states: states,
            ignored: ignored
        )
    }

    private static func completeRecordData(from data: Data) -> Data {
        guard data.count >= outputCap else { return data }
        let prefix = data.prefix(outputCap)
        guard let lastNul = prefix.lastIndex(of: 0) else { return Data() }
        return Data(prefix.prefix(through: lastNul))
    }

    private static func parseHeader(
        _ record: String,
        branch: inout String?,
        detachedOID: inout String?
    ) {
        if record.hasPrefix("# branch.head ") {
            let value = String(record.dropFirst("# branch.head ".count))
            branch = value == "(detached)" ? nil : value
            if value != "(detached)" {
                detachedOID = nil
            }
        } else if record.hasPrefix("# branch.oid ") {
            let oid = String(record.dropFirst("# branch.oid ".count))
            if branch == nil {
                detachedOID = String(oid.prefix(7))
            }
        }
    }

    private static func parseOrdinary(
        _ record: String,
        into states: inout [String: GitFileState]
    ) {
        let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9 else { return }
        let xy = fields[1]
        let submodule = fields[2]
        let path = String(fields[8])
        states[path] = state(xy: xy, submodule: submodule)
    }

    private static func parseRename(
        _ record: String,
        into states: inout [String: GitFileState]
    ) {
        guard let path = pathField(record, maxSplits: 9) else { return }
        states[path] = .staged
    }

    private static func pathField(_ record: String, maxSplits: Int) -> String? {
        let fields = record.split(separator: " ", maxSplits: maxSplits, omittingEmptySubsequences: false)
        guard fields.count == maxSplits + 1 else { return nil }
        return String(fields[maxSplits])
    }

    private static func state(xy: Substring, submodule: Substring) -> GitFileState {
        guard let index = xy.first else { return .clean }
        let worktree = xy.dropFirst().first ?? "."
        if index != "." {
            return .staged
        }
        if worktree != "." {
            return .modified
        }
        if submodule != "N..." {
            return .modified
        }
        return .clean
    }
}
