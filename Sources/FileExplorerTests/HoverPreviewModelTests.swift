import Foundation
import UniformTypeIdentifiers
import CoreGraphics
import FileExplorerCore

@MainActor
func hoverPreviewModelTests() async {
    func entry(_ name: String, type: UTType?) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/t/\(name)"), name: name,
                  isDirectory: false, isHidden: false, isSymlink: false,
                  size: 1, created: nil, modified: .distantPast, contentType: type)
    }

    await test("HoverPreviewModel presents previewables after the delay") {
        let model = HoverPreviewModel(delay: .milliseconds(50))
        let image = entry("pic.png", type: UTType(filenameExtension: "png"))
        expect(HoverPreviewModel.isPreviewable(image), "png is previewable")

        model.hoverBegan(image)
        expect(model.presented == nil, "not presented before delay")
        try await Task.sleep(for: .milliseconds(150))
        expectEqual(model.presented?.url, image.url, "presented after delay")

        model.hoverEnded()
        expect(model.presented == nil, "dismissed on hover end")
    }

    await test("HoverPreviewModel ignores non-previewables and cancels on early exit") {
        let model = HoverPreviewModel(delay: .milliseconds(50))
        let archive = entry("archive.zip", type: UTType(filenameExtension: "zip"))
        expect(!HoverPreviewModel.isPreviewable(archive), "zip not previewable")
        model.hoverBegan(archive)
        try await Task.sleep(for: .milliseconds(150))
        expect(model.presented == nil, "non-previewable never presents")

        let pdf = entry("doc.pdf", type: UTType(filenameExtension: "pdf"))
        expect(HoverPreviewModel.isPreviewable(pdf), "pdf is previewable")
        model.hoverBegan(pdf)
        model.hoverEnded()   // leave before the delay elapses
        try await Task.sleep(for: .milliseconds(150))
        expect(model.presented == nil, "early exit cancels the pending preview")
    }

    await test("HoverPreviewModel retarget replaces pending hover") {
        let model = HoverPreviewModel(delay: .milliseconds(50))
        let first = entry("a.png", type: UTType(filenameExtension: "png"))
        let second = entry("b.png", type: UTType(filenameExtension: "png"))
        model.hoverBegan(first)
        model.hoverBegan(second)   // moved to another row before delay
        try await Task.sleep(for: .milliseconds(150))
        expectEqual(model.presented?.url, second.url, "latest hover wins")
    }

    await test("HoverPreviewModel renders the presented file's image") {
        // Real file: model must eventually publish a rendered CGImage.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("real.png")
        try writeTestPNG(to: png, width: 64, height: 64)   // helper from PreviewRendererTests — move it to file scope there so both suites can use it
        let real = FileEntry(url: png, name: "real.png", isDirectory: false,
                             isHidden: false, isSymlink: false, size: 1,
                             created: nil, modified: .distantPast,
                             contentType: UTType(filenameExtension: "png"))

        let model = HoverPreviewModel(delay: .milliseconds(20))
        model.hoverBegan(real)
        try await Task.sleep(for: .milliseconds(400))
        expect(model.presented != nil, "presented")
        expect(model.presentedImage != nil, "rendered image published")
        model.hoverEnded()
        expect(model.presentedImage == nil, "image cleared on hover end")
    }

    await test("HoverPreviewModel renders markdown and code text") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markdown = dir.appendingPathComponent("README.md")
        try Data("# Notes\n\n```swift\nlet preview = true\n```\n".utf8).write(to: markdown)
        let real = FileEntry(url: markdown, name: "README.md", isDirectory: false,
                             isHidden: false, isSymlink: false, size: 1,
                             created: nil, modified: .distantPast,
                             contentType: UTType(filenameExtension: "md"))
        expect(HoverPreviewModel.isPreviewable(real), "markdown is previewable")

        let model = HoverPreviewModel(delay: .milliseconds(20))
        model.hoverBegan(real)
        try await Task.sleep(for: .milliseconds(400))
        expect(model.presented != nil, "presented")
        expect(model.presentedText?.contains("let preview = true") == true,
               "rendered text published")
        model.hoverEnded()
        expect(model.presentedText == nil, "text cleared on hover end")
    }

    await test("retarget clears the previous rendered image immediately") {
        // Slow injected renderer: returns a real 1x1 image after 300 ms, so we
        // can observe the window between retarget and the new render landing.
        let pixel: CGImage = {
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }()
        let model = HoverPreviewModel(delay: .milliseconds(20)) { _, _ in
            try? await Task.sleep(for: .milliseconds(300))
            return .image(pixel)
        }
        func entry(_ name: String) -> FileEntry {
            FileEntry(url: URL(fileURLWithPath: "/t/\(name)"), name: name,
                      isDirectory: false, isHidden: false, isSymlink: false,
                      size: 1, created: nil, modified: .distantPast,
                      contentType: UTType(filenameExtension: "png"))
        }

        model.hoverBegan(entry("a.png"))
        try await Task.sleep(for: .milliseconds(600))
        expect(model.presentedImage != nil, "first image rendered")

        model.hoverBegan(entry("b.png"))
        try await Task.sleep(for: .milliseconds(120)) // past 20 ms delay, well before 300 ms render
        expectEqual(model.presented?.name, "b.png", "retargeted")
        expect(model.presentedImage == nil,
               "stale first image cleared while second render is pending")
        model.hoverEnded()
    }
}
