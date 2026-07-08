import Foundation

/// Reads and writes Finder comments using Finder's metadata xattr payload.
/// The value is a binary plist string stored at
/// `com.apple.metadata:kMDItemFinderComment`.
public enum CommentWriter {
    private static let xattrName = "com.apple.metadata:kMDItemFinderComment"

    public static func encode(_ comment: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: comment, format: .binary, options: 0)
    }

    public static func read(from url: URL) -> String? {
        let length = getxattr(url.path, xattrName, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes {
            getxattr(url.path, xattrName, $0.baseAddress, length, 0, 0)
        }
        guard read > 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)) as? String
    }

    public static func write(_ comment: String, to url: URL)
        -> Result<Void, FileOperationService.FileOpError> {
        do {
            if comment.isEmpty {
                if removexattr(url.path, xattrName, 0) != 0, errno != ENOATTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return .success(())
            }
            let data = try encode(comment)
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
}
