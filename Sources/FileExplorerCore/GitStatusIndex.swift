import Foundation

public struct GitStatusIndex: Sendable {
    private let repoRootPath: String
    private let states: [String: GitFileState]
    private let directoryStates: [String: GitFileState]
    private let ignoredPaths: Set<String>
    private let ignoredDirectories: Set<String>

    public let branchLabel: String?
    public let changedCount: Int

    public init(status: GitRepoStatus, repoRoot: URL) {
        self.repoRootPath = repoRoot.standardizedFileURL.path
        self.changedCount = status.changedCount
        if let branch = status.branch {
            self.branchLabel = branch
        } else if let detachedOID = status.detachedOID {
            self.branchLabel = "detached \(detachedOID)"
        } else {
            self.branchLabel = nil
        }

        var normalizedStates: [String: GitFileState] = [:]
        var aggregates: [String: GitFileState] = [:]
        for (rawPath, state) in status.states where state != .clean {
            let isDirectoryShape = rawPath.hasSuffix("/")
            let path = Self.normalizedPath(rawPath)
            normalizedStates[path] = max(normalizedStates[path] ?? .clean, state)
            if isDirectoryShape {
                aggregates[path] = max(aggregates[path] ?? .clean, state)
            }
            for ancestor in Self.ancestorDirectories(of: path) {
                aggregates[ancestor] = max(aggregates[ancestor] ?? .clean, state)
            }
        }
        self.states = normalizedStates
        self.directoryStates = aggregates

        var ignoredPaths = Set<String>()
        var ignoredDirectories = Set<String>()
        for rawPath in status.ignored {
            let path = Self.normalizedPath(rawPath)
            ignoredPaths.insert(path)
            if rawPath.hasSuffix("/") {
                ignoredDirectories.insert(path)
            }
        }
        self.ignoredPaths = ignoredPaths
        self.ignoredDirectories = ignoredDirectories
    }

    public func state(for url: URL) -> GitFileState {
        guard let path = relativePath(for: url) else { return .clean }
        if let direct = states[path] {
            return direct
        }
        if let directory = directoryStates[path] {
            return directory
        }
        for ancestor in Self.ancestorDirectoriesNearestFirst(of: path) {
            if let directory = directoryStates[ancestor] {
                return directory
            }
        }
        return .clean
    }

    public func isIgnored(_ url: URL) -> Bool {
        guard let path = relativePath(for: url) else { return false }
        if ignoredPaths.contains(path) {
            return true
        }
        for ancestor in Self.ancestorDirectoriesIncludingSelf(of: path) {
            if ignoredDirectories.contains(ancestor) {
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

    private static func ancestorDirectoriesIncludingSelf(of path: String) -> [String] {
        let normalized = normalizedPath(path)
        guard !normalized.isEmpty else { return [""] }
        var ancestors = [normalized]
        ancestors.append(contentsOf: ancestorDirectoriesNearestFirst(of: normalized))
        return ancestors
    }

    private static func ancestorDirectoriesNearestFirst(of path: String) -> [String] {
        let parts = normalizedPath(path).split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return [] }
        var result: [String] = []
        for count in stride(from: parts.count - 1, through: 1, by: -1) {
            result.append(parts.prefix(count).joined(separator: "/"))
        }
        return result
    }

    private static func normalizedPath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
