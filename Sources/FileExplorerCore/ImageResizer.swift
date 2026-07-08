import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downsamples images next to the source (`stem@50pct.ext`, `stem@1024px.ext`),
/// keeping the source format. Blocking — call off the main actor. Collisions
/// fail loudly, matching ImageConverter.
public enum ImageResizer {
    public enum Mode: Equatable, Sendable {
        case percent(Int)   // 1–100
        case maxEdge(Int)   // longest edge in pixels

        var suffix: String {
            switch self {
            case .percent(let value): "@\(value)pct"
            case .maxEdge(let value): "@\(value)px"
            }
        }
    }

    public struct ItemResult: Sendable {
        public let source: URL
        public let outcome: Result<URL, FileOperationService.FileOpError>
    }

    public static func resize(_ sources: [URL], mode: Mode,
                              jpegQuality: Double = 0.85) -> [ItemResult] {
        sources.map { source in
            ItemResult(source: source,
                       outcome: resizeOne(source, mode: mode, quality: jpegQuality))
        }
    }

    private static func resizeOne(_ source: URL, mode: Mode, quality: Double)
        -> Result<URL, FileOperationService.FileOpError> {
        let ext = source.pathExtension
        let name = source.deletingPathExtension().lastPathComponent
            + mode.suffix + (ext.isEmpty ? "" : ".\(ext)")
        let output = source.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            return .failure(.init("“\(output.lastPathComponent)” already exists."))
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                  as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return .failure(.init("“\(source.lastPathComponent)” isn't a readable image."))
        }
        let longest = max(width, height)
        let targetEdge: Int
        switch mode {
        case .percent(let value):
            targetEdge = max(1, longest * value / 100)
        case .maxEdge(let value):
            targetEdge = min(longest, value)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: targetEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            imageSource, 0, options as CFDictionary) else {
            return .failure(.init("Couldn't downsample “\(source.lastPathComponent)”."))
        }
        let destinationType = CGImageSourceGetType(imageSource)
            ?? (UTType.png.identifier as CFString)
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, destinationType, 1, nil) else {
            return .failure(.init("Couldn't create “\(output.lastPathComponent)”."))
        }
        var destinationOptions: [CFString: Any] = [:]
        if UTType(destinationType as String)?.conforms(to: .jpeg) == true {
            destinationOptions[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, thumbnail,
                                   destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            return .failure(.init("Failed writing “\(output.lastPathComponent)”."))
        }
        return .success(output)
    }
}
