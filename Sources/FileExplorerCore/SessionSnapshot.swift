import Foundation

/// Serializable stand-in for one `[KeyPathComparator<FileEntry>]` element —
/// `KeyPathComparator` itself is not `Codable`.
public struct SortToken: Codable, Equatable, Sendable {
    public enum Field: String, Codable, Sendable {
        case name, size, kind, modified
    }
    public var field: Field
    public var ascending: Bool

    public init(field: Field, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }
}

public enum SortTokenCoder {
    // `PartialKeyPath` isn't `Sendable`, but this table is a fixed, immutable
    // lookup built once at first access and never mutated.
    nonisolated(unsafe) private static let fields: [(SortToken.Field, PartialKeyPath<FileEntry>)] = [
        (.name, \FileEntry.name),
        (.size, \FileEntry.size),
        (.kind, \FileEntry.kind),
        (.modified, \FileEntry.modified),
    ]

    /// Unknown key paths are dropped (a future column simply won't persist
    /// its sort until added here).
    public static func tokens(
        from comparators: [KeyPathComparator<FileEntry>]
    ) -> [SortToken] {
        comparators.compactMap { comparator in
            guard let match = fields.first(where: { $0.1 == comparator.keyPath })
            else { return nil }
            return SortToken(field: match.0,
                             ascending: comparator.order == .forward)
        }
    }

    /// Empty input restores the app-default name sort (matches
    /// `PaneState.sortOrder`'s initial value, localizedStandard comparator).
    public static func comparators(
        from tokens: [SortToken]
    ) -> [KeyPathComparator<FileEntry>] {
        let restored = tokens.map { token -> KeyPathComparator<FileEntry> in
            var comparator: KeyPathComparator<FileEntry>
            switch token.field {
            case .name:
                comparator = KeyPathComparator(\FileEntry.name,
                                               comparator: .localizedStandard)
            case .size:
                comparator = KeyPathComparator(\FileEntry.size)
            case .kind:
                comparator = KeyPathComparator(\FileEntry.kind)
            case .modified:
                comparator = KeyPathComparator(\FileEntry.modified)
            }
            comparator.order = token.ascending ? .forward : .reverse
            return comparator
        }
        return restored.isEmpty
            ? [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)]
            : restored
    }
}

/// Codable mirror of the persistable slice of the session object graph.
/// Everything except `path` decodes with defaults so snapshots written by
/// older builds keep loading as fields are added (forward compatibility).
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public struct Pane: Codable, Equatable, Sendable {
        public var path: String
        public var showHidden: Bool
        public var viewMode: String
        public var groupBy: Grouper.Axis
        public var filter: FilterState
        public var filterExtensionsText: String
        public var sort: [SortToken]
        public var expandedFolders: [String]

        public init(path: String, showHidden: Bool = false,
                    viewMode: String = "list", groupBy: Grouper.Axis = .none,
                    filter: FilterState = FilterState(),
                    filterExtensionsText: String = "", sort: [SortToken] = [],
                    expandedFolders: [String] = []) {
            self.path = path
            self.showHidden = showHidden
            self.viewMode = viewMode
            self.groupBy = groupBy
            self.filter = filter
            self.filterExtensionsText = filterExtensionsText
            self.sort = sort
            self.expandedFolders = expandedFolders
        }

        enum CodingKeys: String, CodingKey {
            case path, showHidden, viewMode, groupBy, filter, filterExtensionsText, sort
            case expandedFolders
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            showHidden = try container.decodeIfPresent(
                Bool.self, forKey: .showHidden) ?? false
            viewMode = try container.decodeIfPresent(
                String.self, forKey: .viewMode) ?? "list"
            groupBy = try container.decodeIfPresent(
                Grouper.Axis.self, forKey: .groupBy) ?? .none
            filter = try container.decodeIfPresent(
                FilterState.self, forKey: .filter) ?? FilterState()
            filterExtensionsText = try container.decodeIfPresent(
                String.self, forKey: .filterExtensionsText) ?? ""
            sort = try container.decodeIfPresent(
                [SortToken].self, forKey: .sort) ?? []
            expandedFolders = try container.decodeIfPresent(
                [String].self, forKey: .expandedFolders) ?? []
        }

        /// The saved folder if it still exists as a directory, else its
        /// nearest existing directory ancestor, else `fallback`. Relative or
        /// empty paths go straight to `fallback` — `URL(fileURLWithPath:)`
        /// would resolve them against the process working directory, whose
        /// ancestor chain always "exists" and would mask the bad data.
        public func resolvedURL(fallback: URL) -> URL {
            guard path.hasPrefix("/") else { return fallback.standardizedFileURL }
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            let url = URL(fileURLWithPath: path)
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return url.standardizedFileURL
            }
            // ancestorChain is root-first ending with url itself; nearest first.
            let ancestors = url.ancestorChain.dropLast().reversed()
            if let existing = ancestors.first(where: {
                fm.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }) {
                return existing
            }
            return fallback.standardizedFileURL
        }
    }

    public struct Tab: Codable, Equatable, Sendable {
        public var panes: [Pane]
        public var activePaneIndex: Int
        public var showsPreviewPane: Bool

        public init(panes: [Pane], activePaneIndex: Int = 0,
                    showsPreviewPane: Bool = false) {
            self.panes = panes
            self.activePaneIndex = activePaneIndex
            self.showsPreviewPane = showsPreviewPane
        }

        enum CodingKeys: String, CodingKey {
            case panes, activePaneIndex, showsPreviewPane
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            panes = try container.decodeIfPresent([Pane].self, forKey: .panes) ?? []
            activePaneIndex = try container.decodeIfPresent(
                Int.self, forKey: .activePaneIndex) ?? 0
            showsPreviewPane = try container.decodeIfPresent(
                Bool.self, forKey: .showsPreviewPane) ?? false
        }
    }

    public var tabs: [Tab]
    public var activeTabIndex: Int
    public var recentFolders: [String]
    public var favoriteFolders: [String]

    public init(tabs: [Tab], activeTabIndex: Int = 0,
                recentFolders: [String] = [], favoriteFolders: [String] = []) {
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.recentFolders = recentFolders
        self.favoriteFolders = favoriteFolders
    }

    enum CodingKeys: String, CodingKey {
        case tabs, activeTabIndex, recentFolders, favoriteFolders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
        activeTabIndex = try container.decodeIfPresent(
            Int.self, forKey: .activeTabIndex) ?? 0
        recentFolders = try container.decodeIfPresent(
            [String].self, forKey: .recentFolders) ?? []
        favoriteFolders = try container.decodeIfPresent(
            [String].self, forKey: .favoriteFolders) ?? []
    }
}
