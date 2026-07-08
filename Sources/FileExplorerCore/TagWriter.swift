import Foundation

/// Writes Finder tags. Blocking (tiny xattr write); callable from any actor.
/// Read-only volumes surface the underlying error.
///
/// `URLResourceValues.tagNames` only became SETTABLE in macOS 26, so with a
/// macOS 15 deployment target we write the underlying xattr directly in
/// Finder's own format: a binary plist array of "Name\nColorIndex" strings.
/// Reading back via the `.tagNamesKey` resource value (DirectoryLoader)
/// returns plain names — the color suffix is the xattr encoding, not part
/// of the tag name.
public enum TagWriter {
    private static let xattrName = "com.apple.metadata:_kMDItemUserTags"

    /// Finder's color indices for the standard label names; unknown tags get
    /// 0 (no color) and render as gray dots.
    private static let colorIndex: [String: Int] = [
        "Gray": 1, "Grey": 1, "Green": 2, "Purple": 3, "Blue": 4,
        "Yellow": 5, "Red": 6, "Orange": 7,
    ]

    public static func setTags(_ tags: [String], on url: URL)
        -> Result<Void, FileOperationService.FileOpError> {
        do {
            if tags.isEmpty {
                // Removing a never-set attribute is success, not an error.
                if removexattr(url.path, xattrName, 0) != 0, errno != ENOATTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return .success(())
            }
            let payload = tags.map { "\($0)\n\(colorIndex[$0] ?? 0)" }
            let data = try PropertyListSerialization.data(
                fromPropertyList: payload, format: .binary, options: 0)
            let status = data.withUnsafeBytes {
                setxattr(url.path, xattrName, $0.baseAddress, $0.count, 0, 0)
            }
            guard status == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return .success(())
        } catch {
            return .failure(.init(error))
        }
    }

    /// Toggle semantics for the context submenu: if EVERY target already has
    /// the tag, remove it from all; otherwise add it to all. Pure.
    public static func toggledTags(current: [String], tag: String,
                                   removing: Bool) -> [String] {
        removing ? current.filter { $0 != tag }
                 : current.contains(tag) ? current : current + [tag]
    }
}
