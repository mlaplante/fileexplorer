import Foundation
import UniformTypeIdentifiers

/// Immutable snapshot of one directory entry.
///
/// `modified` falls back to `.distantPast` when unreadable because it feeds
/// a sortable table column and must be non-optional; `created` stays optional
/// because it is display-only.
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
    /// Finder tag names (com.apple.metadata:_kMDItemUserTags), empty when none.
    public let tags: [String]

    public var id: URL { url }

    /// Human-readable kind, e.g. "PNG image", "Folder".
    public var kind: String {
        if isDirectory { return "Folder" }
        if let description = contentType?.localizedDescription { return description }
        let ext = url.pathExtension
        return ext.isEmpty ? "Document" : ext.uppercased()
    }

    public init(url: URL, name: String, isDirectory: Bool, isHidden: Bool,
                isSymlink: Bool, size: Int64, created: Date?, modified: Date,
                contentType: UTType?, tags: [String] = []) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.size = size
        self.created = created
        self.modified = modified
        self.contentType = contentType
        self.tags = tags
    }
}
