import Foundation
import ImageIO

/// Reads EXIF DateTimeOriginal ("yyyy:MM:dd HH:mm:ss", local time by EXIF
/// convention). Blocking (tiny header read) — call off the main actor for
/// large batches. Returns nil for non-images or images without the tag.
public enum ExifDateReader {
    public static func captureDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary]
                  as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: raw)
    }
}
