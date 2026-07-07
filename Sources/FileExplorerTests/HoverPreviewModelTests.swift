import Foundation
import UniformTypeIdentifiers
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
        let text = entry("notes.txt", type: UTType(filenameExtension: "txt"))
        expect(!HoverPreviewModel.isPreviewable(text), "txt not previewable")
        model.hoverBegan(text)
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
}
