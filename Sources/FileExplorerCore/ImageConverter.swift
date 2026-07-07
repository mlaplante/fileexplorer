import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts images (anything ImageIO decodes: HEIC, WebP, AVIF, PNG, …) to
/// JPG or PNG next to the source. Blocking — call off the main actor.
/// Collisions fail loudly (no overwrite), matching FileOperationService.
public enum ImageConverter {
    public enum Format: String, CaseIterable, Sendable {
        case jpeg
        case png

        public var fileExtension: String { self == .jpeg ? "jpg" : "png" }
        var utType: UTType { self == .jpeg ? .jpeg : .png }
    }

    public struct ItemResult: Sendable {
        public let source: URL
        public let outcome: Result<URL, FileOperationService.FileOpError>
    }

    public static func convert(_ sources: [URL], to format: Format,
                               jpegQuality: Double = 0.85) -> [ItemResult] {
        sources.map { source in
            ItemResult(source: source,
                       outcome: convertOne(source, to: format, quality: jpegQuality))
        }
    }

    private static func convertOne(_ source: URL, to format: Format,
                                   quality: Double)
        -> Result<URL, FileOperationService.FileOpError> {
        let target = source.deletingPathExtension()
            .appendingPathExtension(format.fileExtension)
        guard target.path != source.path else {
            return .failure(.init("“\(source.lastPathComponent)” is already \(format.fileExtension)."))
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .failure(.init("“\(target.lastPathComponent)” already exists."))
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0,
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return .failure(.init("“\(source.lastPathComponent)” isn't a readable image."))
        }
        guard let destination = CGImageDestinationCreateWithURL(
            target as CFURL, format.utType.identifier as CFString, 1, nil) else {
            return .failure(.init("Couldn't create “\(target.lastPathComponent)”."))
        }
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
            as? [CFString: Any]
        var destinationOptions: [CFString: Any] = [:]
        if format == .jpeg {
            destinationOptions[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if let orientation = sourceProperties?[kCGImagePropertyOrientation] {
            destinationOptions[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: target)
            return .failure(.init("Failed writing “\(target.lastPathComponent)”."))
        }
        return .success(target)
    }
}
