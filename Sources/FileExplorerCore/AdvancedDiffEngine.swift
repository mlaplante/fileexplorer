import Foundation

public struct AdvancedDiffOptions: Equatable, Sendable {
    public var ignoredPatterns: [String]
    public var useChecksum: Bool

    public init(ignoredPatterns: [String] = [], useChecksum: Bool = false) {
        self.ignoredPatterns = ignoredPatterns
        self.useChecksum = useChecksum
    }
}

public struct AdvancedDiffItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case onlyLeft
        case onlyRight
        case differs
        case same
    }

    public var relativePath: String
    public var kind: Kind

    public init(relativePath: String, kind: Kind) {
        self.relativePath = relativePath
        self.kind = kind
    }
}

public enum AdvancedDiffEngine {
    public static func compare(left: URL, right: URL,
                               options: AdvancedDiffOptions = AdvancedDiffOptions())
        -> [AdvancedDiffItem] {
        let leftListing = listing(root: left, options: options)
        let rightListing = listing(root: right, options: options)
        let paths = Set(leftListing.keys).union(rightListing.keys).sorted()
        return paths.map { path in
            guard let lhs = leftListing[path] else {
                return AdvancedDiffItem(relativePath: path, kind: .onlyRight)
            }
            guard let rhs = rightListing[path] else {
                return AdvancedDiffItem(relativePath: path, kind: .onlyLeft)
            }
            return AdvancedDiffItem(
                relativePath: path,
                kind: differs(lhs, rhs, useChecksum: options.useChecksum)
                    ? .differs
                    : .same)
        }
    }

    private struct Signature {
        var isDirectory: Bool
        var size: Int64
        var modified: Date?
        var checksum: String?
    }

    private static func listing(root: URL, options: AdvancedDiffOptions)
        -> [String: Signature] {
        let fm = FileManager.default
        let root = root.standardizedFileURL
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey,
                                         .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [:] }
        var out: [String: Signature] = [:]
        for case let url as URL in enumerator {
            let url = url.standardizedFileURL
            let relative = url.path.hasPrefix(root.path + "/")
                ? String(url.path.dropFirst(root.path.count + 1))
                : url.lastPathComponent
            if isIgnored(relative, patterns: options.ignoredPatterns) {
                let ignoredValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if ignoredValues?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ])
            let isDirectory = values?.isDirectory == true
            let checksum: String?
            if options.useChecksum, !isDirectory,
               case .success(let hash) = FileHasher.sha256(of: url) {
                checksum = hash
            } else {
                checksum = nil
            }
            out[relative] = Signature(isDirectory: isDirectory,
                                      size: Int64(values?.fileSize ?? 0),
                                      modified: values?.contentModificationDate,
                                      checksum: checksum)
        }
        return out
    }

    private static func differs(_ lhs: Signature, _ rhs: Signature,
                                useChecksum: Bool) -> Bool {
        guard lhs.isDirectory == rhs.isDirectory else { return true }
        if lhs.isDirectory { return false }
        if lhs.size != rhs.size { return true }
        if useChecksum { return lhs.checksum != rhs.checksum }
        return abs((lhs.modified ?? .distantPast)
            .timeIntervalSince(rhs.modified ?? .distantPast)) > 2
    }

    private static func isIgnored(_ relativePath: String,
                                  patterns: [String]) -> Bool {
        patterns.contains { pattern in
            guard !pattern.isEmpty else { return false }
            if pattern.contains("*") {
                return wildcard(pattern, matches: relativePath)
            }
            return relativePath == pattern || relativePath.hasPrefix(pattern + "/")
        }
    }

    private static func wildcard(_ pattern: String, matches value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        return value.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }
}
