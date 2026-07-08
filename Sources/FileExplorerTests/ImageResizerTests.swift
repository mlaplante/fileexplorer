import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FileExplorerCore

@MainActor
func imageResizerTests() async {
    func writePNG(to url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: colorSpace,
                                     components: [0, 0, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "test", code: 1)
        }
    }
    func dimensions(of url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    await test("maxEdge resize caps the longest edge and names @Npx") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-resize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("wide.png")
        try writePNG(to: source, width: 200, height: 100)
        let results = ImageResizer.resize([source], mode: .maxEdge(50))
        guard case .success(let output) = results[0].outcome else {
            return expect(false, "resize succeeds")
        }
        expectEqual(output.lastPathComponent, "wide@50px.png", "output name")
        let dims = dimensions(of: output)
        expectEqual(dims?.0, 50, "width capped")
        expectEqual(dims?.1, 25, "aspect kept")
    }

    await test("percent resize scales and names @Npct") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-resize2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("square.png")
        try writePNG(to: source, width: 100, height: 100)
        let results = ImageResizer.resize([source], mode: .percent(50))
        guard case .success(let output) = results[0].outcome else {
            return expect(false, "resize succeeds")
        }
        expectEqual(output.lastPathComponent, "square@50pct.png", "output name")
        expectEqual(dimensions(of: output)?.0, 50, "scaled")
    }

    await test("collision fails loudly and non-images fail per item") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-resize3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.png")
        try writePNG(to: source, width: 10, height: 10)
        try "occupied".write(to: dir.appendingPathComponent("a@50pct.png"),
                             atomically: true, encoding: .utf8)
        guard case .failure = ImageResizer.resize([source], mode: .percent(50))[0].outcome
        else { return expect(false, "collision rejected") }
        let text = dir.appendingPathComponent("not-image.txt")
        try "words".write(to: text, atomically: true, encoding: .utf8)
        guard case .failure = ImageResizer.resize([text], mode: .percent(50))[0].outcome
        else { return expect(false, "non-image rejected") }
        expect(true, "both failures surfaced")
    }
}
