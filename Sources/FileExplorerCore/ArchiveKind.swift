import Foundation

/// Pure detection of extractable archives from a file name. Bare .gz/.bz2
/// (single compressed files, not tarballs) are deliberately unsupported.
public enum ArchiveKind: Equatable, Sendable {
    case zip
    case tarball

    private static let tarSuffixes =
        [".tar.gz", ".tar.bz2", ".tar.xz", ".tar", ".tgz", ".tbz", ".txz"]

    public static func detect(_ name: String) -> ArchiveKind? {
        let lower = name.lowercased()
        if lower.hasSuffix(".zip") { return .zip }
        if tarSuffixes.contains(where: lower.hasSuffix) { return .tarball }
        return nil
    }

    /// "Photos.zip" → "Photos"; "src.tar.gz" → "src". Names without a
    /// recognized suffix pass through unchanged.
    public static func stem(_ name: String) -> String {
        let lower = name.lowercased()
        for suffix in [".zip"] + tarSuffixes where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}
