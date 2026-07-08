import Foundation

/// A named saved search scoped to one folder. Identity is the name: saving
/// under an existing name replaces that smart folder.
public struct SmartFolder: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var rootPath: String
    public var filter: FilterState

    public var id: String { name }

    public init(name: String, root: URL, filter: FilterState) {
        self.name = name
        self.rootPath = root.standardizedFileURL.path
        self.filter = filter
    }

    public var rootURL: URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
    }
}
