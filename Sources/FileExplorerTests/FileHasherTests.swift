import Foundation
import FileExplorerCore

@MainActor
func fileHasherTests() async {
    await test("sha256 matches the known vector for 'abc'") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("abc.txt")
        try "abc".write(to: file, atomically: true, encoding: .utf8)
        guard case .success(let hash) = FileHasher.sha256(of: file) else {
            return expect(false, "hash succeeds")
        }
        expectEqual(hash,
                    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                    "NIST test vector")
    }

    await test("sha256 streams large files and fails on missing ones") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-hash2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.bin")
        try Data(repeating: 0xAB, count: 3 * 1_048_576).write(to: big)
        guard case .success(let hash) = FileHasher.sha256(of: big) else {
            return expect(false, "large file hashed")
        }
        expectEqual(hash.count, 64, "64 hex chars")
        guard case .failure = FileHasher.sha256(
            of: dir.appendingPathComponent("missing")) else {
            return expect(false, "missing file fails")
        }
        expect(true, "failure surfaced")
    }

    await test("FileHasher prefix hash distinguishes prefix from full content") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hasher-prefix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var shared = Data(repeating: 0xAB, count: 128 * 1024)
        let a = dir.appendingPathComponent("a.bin")
        try shared.write(to: a)
        shared[shared.count - 1] = 0x00  // same first 64 KB, different tail
        let b = dir.appendingPathComponent("b.bin")
        try shared.write(to: b)

        let prefixA = try FileHasher.sha256(of: a, firstBytes: 65_536).get()
        let prefixB = try FileHasher.sha256(of: b, firstBytes: 65_536).get()
        expectEqual(prefixA, prefixB, "identical prefixes hash equal")

        let fullA = try FileHasher.sha256(of: a).get()
        let fullB = try FileHasher.sha256(of: b).get()
        expect(fullA != fullB, "different tails hash differently")

        let capped = try FileHasher.sha256(of: a, firstBytes: 1 << 30).get()
        expectEqual(capped, fullA, "cap beyond file size equals full hash")
    }
}
