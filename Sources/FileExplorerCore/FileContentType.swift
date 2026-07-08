import Foundation
import UniformTypeIdentifiers

public enum FileContentType {
    public static func resolve(for url: URL, resourceType: UTType? = nil) -> UTType? {
        if let resourceType, !resourceType.identifier.hasPrefix("dyn.") {
            return resourceType
        }
        return declaredType(forExtension: url.pathExtension) ?? resourceType
    }

    private static func declaredType(forExtension pathExtension: String) -> UTType? {
        switch pathExtension.lowercased() {
        case "txt", "text", "log", "cfg", "conf", "ini":
            return .plainText
        case "md", "markdown":
            return .plainText
        case "json":
            return .json
        case "xml":
            return .xml
        case "plist":
            return .propertyList
        case "swift":
            return .swiftSource
        case "html", "htm":
            return .html
        case "css":
            return .css
        case "csv":
            return .commaSeparatedText
        case "pdf":
            return .pdf
        case "png":
            return .png
        case "jpg", "jpeg":
            return .jpeg
        case "heic":
            return .heic
        case "tif", "tiff":
            return .tiff
        case "gif":
            return .gif
        case "mp4", "m4v":
            return .mpeg4Movie
        case "mov":
            return .quickTimeMovie
        default:
            return nil
        }
    }
}
