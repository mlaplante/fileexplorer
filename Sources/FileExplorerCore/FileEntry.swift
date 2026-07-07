import Foundation
import UniformTypeIdentifiers

public struct FileEntry: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isHidden: Bool
    public let isSymlink: Bool
    public let size: Int64
    public let created: Date?
    public let modified: Date
    public let contentType: UTType?

    public var id: URL { url }

    /// Human-readable kind, e.g. "PNG image", "Folder".
    public var kind: String {
        if isDirectory { return "Folder" }
        return contentType?.localizedDescription
            ?? url.pathExtension.uppercased()
    }

    public init(url: URL, name: String, isDirectory: Bool, isHidden: Bool,
                isSymlink: Bool, size: Int64, created: Date?, modified: Date,
                contentType: UTType?) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.size = size
        self.created = created
        self.modified = modified
        self.contentType = contentType
    }
}
