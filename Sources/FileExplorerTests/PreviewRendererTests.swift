import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FileExplorerCore

func writeTestPNG(to url: URL, width: Int, height: Int) throws {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "test", code: 1)
    }
}

func writeTestPDF(to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 100)
    let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
    context.endPDFPage()
    context.closePDF()
}

@MainActor
func previewRendererTests() async {
    await test("PreviewRenderer downsamples images to the max dimension") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("big.png")
        try writeTestPNG(to: png, width: 800, height: 400)

        let image = PreviewRenderer.downsampledImage(at: png, maxDimension: 200)
        expect(image != nil, "png renders")
        expectEqual(max(image!.width, image!.height), 200, "downsampled to max 200")

        let small = PreviewRenderer.downsampledImage(at: png, maxDimension: 2000)
        expectEqual(max(small!.width, small!.height), 800,
                    "never upscales beyond source size")
    }

    await test("PreviewRenderer renders PDF first pages and rejects non-previews") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("doc.pdf")
        try writeTestPDF(to: pdf)
        let page = PreviewRenderer.pdfFirstPage(at: pdf, maxDimension: 400)
        expect(page != nil, "pdf first page renders")
        expect(page!.width > 0 && page!.height > 0, "non-empty raster")

        let text = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        expect(PreviewRenderer.downsampledImage(at: text, maxDimension: 200) == nil,
               "text file is not an image")
        expect(PreviewRenderer.pdfFirstPage(at: text, maxDimension: 200) == nil,
               "text file is not a pdf")
    }

    await test("PaneState viewMode defaults to list and toggles") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = PaneState(url: dir)
        expectEqual(pane.viewMode, .list, "list by default")
        pane.viewMode = .icons
        expectEqual(pane.viewMode, .icons, "switches to icons")
    }
}
