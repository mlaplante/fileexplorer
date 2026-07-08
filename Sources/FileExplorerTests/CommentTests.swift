import Foundation
import FileExplorerCore

@MainActor
func commentTests() async {
    let fm = FileManager.default

    await test("CommentWriter encodes comments as binary plist strings") {
        let data = try CommentWriter.encode("hello")
        var format = PropertyListSerialization.PropertyListFormat.binary
        let value = try PropertyListSerialization.propertyList(
            from: data, options: [], format: &format)
        expectEqual(format, .binary, "payload is a binary plist")
        expectEqual(value as? String, "hello", "plist decodes to the comment")
    }

    await test("CommentWriter writes and reads the Finder comment xattr") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("commented.txt")
        try Data().write(to: file)

        guard case .success = CommentWriter.write("hello", to: file) else {
            return expect(false, "write succeeds")
        }
        expectEqual(CommentWriter.read(from: file), "hello",
                    "read returns written comment")
        let raw = readCommentXattr(file)
        expect(raw != nil, "xattr exists on disk")
    }

    await test("CommentWriter write failure is reported") {
        let missing = URL(fileURLWithPath: "/tmp/no-such-comment-\(UUID().uuidString)")
        if case .failure = CommentWriter.write("hello", to: missing) {
            expect(true, "missing file write returns failure")
        } else {
            expect(false, "missing file write returns failure")
        }
    }

    await test("CommentWriter read with no comment returns nil") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("plain.txt")
        try Data().write(to: file)
        expect(CommentWriter.read(from: file) == nil, "no comment is nil")
    }

    await test("InfoGatherer includes Finder comments") {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("info.txt")
        try Data().write(to: file)
        _ = CommentWriter.write("info comment", to: file)
        let info = InfoGatherer.info(for: file)
        expectEqual(info?.finderComment, "info comment",
                    "comment gathered for Get Info")
    }
}

private func readCommentXattr(_ url: URL) -> Data? {
    let name = "com.apple.metadata:kMDItemFinderComment"
    let length = getxattr(url.path, name, nil, 0, 0, 0)
    guard length > 0 else { return nil }
    var data = Data(count: length)
    let read = data.withUnsafeMutableBytes {
        getxattr(url.path, name, $0.baseAddress, length, 0, 0)
    }
    return read > 0 ? data : nil
}
