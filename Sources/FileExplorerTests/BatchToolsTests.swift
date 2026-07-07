import Foundation
import ImageIO
import FileExplorerCore

@MainActor
func batchToolsTests() async {
    let fm = FileManager.default

    await test("ImageConverter converts png to jpg and reports failures") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let png = dir.appendingPathComponent("pic.png")
        try writeTestPNG(to: png, width: 32, height: 32)
        try Data("not an image".utf8).write(to: dir.appendingPathComponent("fake.png"))

        let results = ImageConverter.convert(
            [png, dir.appendingPathComponent("fake.png")], to: .jpeg)
        expectEqual(results.count, 2, "one result per input")

        if case .success(let out) = results[0].outcome {
            expectEqual(out.pathExtension, "jpg", "jpg extension")
            expect(fm.fileExists(atPath: out.path), "output exists")
            let source = CGImageSourceCreateWithURL(out as CFURL, nil)
            expect(source != nil && CGImageSourceGetCount(source!) > 0,
                   "output is a decodable image")
            expect(fm.fileExists(atPath: png.path), "source untouched")
        } else { expect(false, "png→jpg should succeed") }

        if case .success = results[1].outcome {
            expect(false, "non-image must fail")
        } else { expect(true, "fake image failed cleanly") }

        // collision: converting again must fail loudly, not overwrite
        let again = ImageConverter.convert([png], to: .jpeg)
        if case .success = again[0].outcome {
            expect(false, "existing pic.jpg must not be overwritten")
        } else { expect(true, "collision rejected") }
    }

    await test("Zipper compresses a selection into a unique archive") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        try Data("aa".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data("bb".utf8).write(to: sub.appendingPathComponent("b.txt"))

        let first = Zipper.compress(
            [dir.appendingPathComponent("a.txt"), sub], in: dir)
        if case .success(let archive) = first {
            expectEqual(archive.lastPathComponent, "Archive.zip", "default name")
            expect(fm.fileExists(atPath: archive.path), "archive exists")
            let listing = try listZip(archive)
            expect(listing.contains("a.txt") && listing.contains("sub/b.txt"),
                   "relative paths inside [got: \(listing)]")
        } else { expect(false, "zip should succeed") }

        let second = Zipper.compress([dir.appendingPathComponent("a.txt")], in: dir)
        if case .success(let archive2) = second {
            expectEqual(archive2.lastPathComponent, "Archive 2.zip", "uniquified")
        } else { expect(false, "second zip should succeed") }
    }

    await test("FolderSizer sums recursive file sizes") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        try Data(count: 100).write(to: dir.appendingPathComponent("a.bin"))
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data(count: 250).write(to: sub.appendingPathComponent("b.bin"))

        expectEqual(FolderSizer.size(of: dir), 350, "recursive byte total")
        expectEqual(FolderSizer.size(of: dir.appendingPathComponent("missing")), 0,
                    "missing folder is 0")
    }
}

func listZip(_ archive: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
    process.arguments = ["-1", archive.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                  encoding: .utf8) ?? ""
}
