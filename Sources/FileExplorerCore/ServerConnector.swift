import Foundation

public enum ServerConnector {
    public static let supportedSchemes: Set<String> = [
        "smb", "afp", "nfs", "webdav", "webdavs", "ftp", "sftp"
    ]

    public static func normalizedURL(from input: String,
                                     defaultScheme: String = "smb") -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://")
            ? trimmed
            : "\(defaultScheme)://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              supportedSchemes.contains(scheme)
        else { return nil }
        components.scheme = scheme
        guard components.host?.isEmpty == false else { return nil }
        return components.url
    }
}
