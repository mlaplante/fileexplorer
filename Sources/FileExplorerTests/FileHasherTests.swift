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
}
