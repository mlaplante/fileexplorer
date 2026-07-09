import Foundation

public struct GitStatusIndex: Sendable {
    private let repoRootPath: String
    private let states: [String: GitFileState]
    private let ignored: Set<String>
    private let directoryStates: [String: GitFileState]

    public let branchLabel: String?
    public let changedCount: Int

    public init(status: GitRepoStatus, repoRoot: URL) {
        self.repoRootPath = repoRoot.standardizedFileURL.path
        self.states = status.states
        self.ignored = status.ignored
        self.changedCount = status.changedCount
        if let branch = status.branch {
            self.branchLabel = branch
        } else if let detachedOID = status.detachedOID {
            self.branchLabel = "detached \(detachedOID)"
        } else {
            self.branchLabel = nil
        }

        var aggregates: [String: GitFileState] = [:]
        for (path, state) in status.states where state != .ignored && state != .clean {
            for ancestor in Self.ancestorDirectories(of: path) {
                aggregates[ancestor] = max(aggregates[ancestor] ?? .clean, state)
            }
        }
        self.directoryStates = aggregates
    }

    public func state(for url: URL) -> GitFileState {
        guard let path = relativePath(for: url) else { return .clean }
        if let direct = states[path] {
            return direct
        }
        return directoryStates[path] ?? .clean
    }

    public func isIgnored(_ url: URL) -> Bool {
        guard let path = relativePath(for: url) else { return false }
        for ignoredPath in ignored {
            let normalized = ignoredPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path == normalized || path.hasPrefix(normalized + "/") {
                return true
            }
        }
        return false
    }

    private func relativePath(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if path == repoRootPath {
            return ""
        }
        let prefix = repoRootPath.hasSuffix("/") ? repoRootPath : repoRootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private static func ancestorDirectories(of path: String) -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return [""] }
        var ancestors = [""]
        if parts.count > 1 {
            var current = ""
            for part in parts.dropLast() {
                current = current.isEmpty ? String(part) : current + "/" + part
                ancestors.append(current)
            }
        }
        return ancestors
    }
}
