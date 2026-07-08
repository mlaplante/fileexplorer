import Foundation

/// Per-file inputs for date-token expansion; gathered by the UI layer
/// (impure) and injected so planning stays pure.
public struct RenameTokenMetadata: Equatable, Sendable {
    public let modified: Date
    public let exifDate: Date?

    public init(modified: Date, exifDate: Date?) {
        self.modified = modified
        self.exifDate = exifDate
    }
}

/// Pure `{modified:FORMAT}` / `{exif:FORMAT}` expansion. Formats use
/// DateFormatter patterns with a fixed POSIX locale so output is stable.
/// `{exif:…}` falls back to the modified date when EXIF is absent.
public enum RenameTokens {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\{(modified|exif):([^}]+)\}"#)

    public static func expand(_ template: String,
                              metadata: RenameTokenMetadata) -> String {
        let mutable = NSMutableString(string: template)
        let matches = pattern.matches(
            in: template, range: NSRange(location: 0, length: mutable.length))
        for match in matches.reversed() {
            let kind = mutable.substring(with: match.range(at: 1))
            let format = mutable.substring(with: match.range(at: 2))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            let date = kind == "exif"
                ? (metadata.exifDate ?? metadata.modified)
                : metadata.modified
            mutable.replaceCharacters(in: match.range,
                                      with: formatter.string(from: date))
        }
        return mutable as String
    }

    public enum CaseTransform: String, CaseIterable, Sendable {
        case upper = "UPPERCASE"
        case lower = "lowercase"
        case title = "Title Case"

        public func apply(to stem: String) -> String {
            switch self {
            case .upper: stem.uppercased()
            case .lower: stem.lowercased()
            case .title: stem.capitalized
            }
        }
    }
}
