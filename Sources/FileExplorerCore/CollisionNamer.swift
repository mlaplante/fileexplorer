import Foundation

/// Pure collision-free naming. Callers pass the set of names already taken
/// in the destination (from a directory listing); the actual filesystem
/// operation is still the authority and fails loudly if a race or a
/// case-folding mismatch (APFS is case-insensitive) slips a collision past
/// the listing.
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

    /// Strips an existing Finder copy suffix so repeat duplication counts up
    /// ("photo copy" → "photo", "photo copy 2" → "photo") instead of
    /// stacking ("photo copy copy").
    static func baseStem(_ stem: String) -> String {
        if stem.hasSuffix(" copy") { return String(stem.dropLast(" copy".count)) }
        if let range = stem.range(of: #" copy \d+$"#, options: .regularExpression) {
            return String(stem[..<range.lowerBound])
        }
        return stem
    }

    /// Finder-style duplicate/paste naming: "photo.jpg" → "photo copy.jpg"
    /// → "photo copy 2.jpg" → … Returns `name` unchanged when it's free.
    public static func copyName(for name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let (rawStem, ext) = split(name)
        let stem = baseStem(rawStem)
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
