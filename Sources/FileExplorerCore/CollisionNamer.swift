import Foundation

/// Pure collision-free naming. Callers pass the set of names already taken
/// in the destination (from a directory listing); the actual filesystem
/// operation is still the authority and fails loudly if a race slips a
/// collision past the listing.
public enum CollisionNamer {
    /// Splits "name.ext" into ("name", ".ext"). Dotfiles and extensionless
    /// names keep the whole name as the stem.
    static func split(_ name: String) -> (stem: String, ext: String) {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        guard !ext.isEmpty, !stem.isEmpty else { return (name, "") }
        return (stem, "." + ext)
    }

    /// Finder-style duplicate/paste naming: "photo.jpg" → "photo copy.jpg"
    /// → "photo copy 2.jpg" → … Returns `name` unchanged when it's free.
    public static func copyName(for name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let (stem, ext) = split(name)
        var candidate = "\(stem) copy\(ext)"
        var counter = 1
        while existing.contains(candidate) {
            counter += 1
            candidate = "\(stem) copy \(counter)\(ext)"
        }
        return candidate
    }

    /// "untitled" → "untitled 2" → "untitled 3" → … (New File, extraction
    /// folder). Matches the counting style newFolder has always used.
    public static func sequentialName(base: String, existing: Set<String>) -> String {
        var candidate = base
        var counter = 1
        while existing.contains(candidate) {
            counter += 1
            candidate = "\(base) \(counter)"
        }
        return candidate
    }
}
