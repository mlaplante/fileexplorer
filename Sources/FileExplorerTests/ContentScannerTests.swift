import Foundation
import UniformTypeIdentifiers
import FileExplorerCore

@MainActor
func contentScannerTests() async {
    await test("isTextLike gates by type and extension") {
        expect(ContentScanner.isTextLike(UTType.plainText, pathExtension: "txt"),
               "plain text passes")
        expect(ContentScanner.isTextLike(UTType.swiftSource, pathExtension: "swift"),
               "source code passes")
        expect(ContentScanner.isTextLike(UTType.json, pathExtension: "json"),
               "json passes")
        expect(!ContentScanner.isTextLike(UTType.jpeg, pathExtension: "jpg"),
               "images rejected")
        expect(ContentScanner.isTextLike(nil, pathExtension: "md"),
               "unknown type falls back to known text extension")
        expect(!ContentScanner.isTextLike(nil, pathExtension: "bin"),
               "unknown type + unknown extension rejected")
    }

    await test("scan finds case-insensitive substring matches in text files") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "The NEEDLE is here".write(
            to: dir.appendingPathComponent("hit.txt"), atomically: true, encoding: .utf8)
        try "nothing to see".write(
            to: dir.appendingPathComponent("miss.txt"), atomically: true, encoding: .utf8)
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "needle again".write(
            to: sub.appendingPathComponent("nested.md"), atomically: true, encoding: .utf8)
        try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent("skip.jpg"))

        let hits = ContentScanner.scan(root: dir, query: "needle")
        let names = Set(hits.map(\.lastPathComponent))
        expectEqual(names, ["hit.txt", "nested.md"], "case-insensitive, recursive")
    }

    await test("scan respects the per-file size cap") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-scancap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = String(repeating: "x", count: 4096) + "needle"
        try big.write(to: dir.appendingPathComponent("big.txt"),
                      atomically: true, encoding: .utf8)
        let capped = ContentScanner.scan(root: dir, query: "needle",
                                         maxFileBytes: 1024)
        expect(capped.isEmpty, "oversized file skipped")
        let uncapped = ContentScanner.scan(root: dir, query: "needle")
        expectEqual(uncapped.count, 1, "default cap admits the file")
    }

    await test("empty query matches nothing") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-scanempty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "content".write(to: dir.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)
        expect(ContentScanner.scan(root: dir, query: "  ").isEmpty,
               "blank query → no results")
    }
}
