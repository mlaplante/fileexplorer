import Foundation
import CoreServices
import UniformTypeIdentifiers

/// Everything the Get Info panel shows for one item. Value type so it can
/// cross from a detached gathering task to the MainActor model.
public struct ItemInfo: Equatable, Sendable {
    public let url: URL
    public let name: String
    public let kind: String
    /// nil for directories — recursive size is on-demand (FolderSizer),
    /// never computed implicitly.
    public let size: Int64?
    public let isDirectory: Bool
    public let created: Date?
    public let modified: Date?
    public let permissions: String
    public let owner: String
    public let group: String
    public let whereFroms: [String]
    public let symlinkTarget: String?
}

/// Blocking metadata read — call off the main actor. Uses lstat-style
/// attributes so a symlink reports itself, plus its target for display.
public enum InfoGatherer {
    public static func info(for url: URL) -> ItemInfo? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let type = attrs[.type] as? FileAttributeType
        let isSymlink = type == .typeSymbolicLink
        let isDirectory = type == .typeDirectory
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0

        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        let kind: String
        if isDirectory {
            kind = "Folder"
        } else if isSymlink {
            kind = "Alias (symbolic link)"
        } else {
            kind = values?.contentType?.localizedDescription
                ?? (url.pathExtension.isEmpty ? "Document"
                                              : url.pathExtension.uppercased())
        }

        var whereFroms: [String] = []
        if let mdItem = MDItemCreate(nil, url.path as CFString),
           let value = MDItemCopyAttribute(mdItem, kMDItemWhereFroms) as? [String] {
            whereFroms = value
        }

        return ItemInfo(
            url: url,
            name: url.lastPathComponent,
            kind: kind,
            size: isDirectory ? nil : (attrs[.size] as? NSNumber)?.int64Value,
            isDirectory: isDirectory,
            created: attrs[.creationDate] as? Date,
            modified: attrs[.modificationDate] as? Date,
            permissions: permissionString(mode: mode),
            owner: attrs[.ownerAccountName] as? String ?? "",
            group: attrs[.groupOwnerAccountName] as? String ?? "",
            whereFroms: whereFroms,
            symlinkTarget: isSymlink
                ? (try? fm.destinationOfSymbolicLink(atPath: url.path))
                : nil)
    }

    /// "rwxr-xr-x" from a POSIX mode. Pure.
    /// (Written as explicit statements: the map/ternary/shift one-liner
    /// exceeds the type-checker budget on CI's older Swift toolchain.)
    public static func permissionString(mode: Int) -> String {
        let bits = ["r", "w", "x"]
        var result = ""
        for index in 0..<9 {
            let bit = (mode >> (8 - index)) & 1
            result += bit == 1 ? bits[index % 3] : "-"
        }
        return result
    }
}
