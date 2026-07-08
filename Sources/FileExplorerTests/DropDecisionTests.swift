import Foundation
import FileExplorerCore

@MainActor
func dropDecisionTests() async {
    await test("decide follows Finder parity") {
        expectEqual(DropDecision.decide(optionDown: false, sameVolume: true),
                    .move, "same volume, no modifier → move")
        expectEqual(DropDecision.decide(optionDown: false, sameVolume: false),
                    .copy, "cross volume, no modifier → copy")
        expectEqual(DropDecision.decide(optionDown: true, sameVolume: true),
                    .copy, "option forces copy on same volume")
        expectEqual(DropDecision.decide(optionDown: true, sameVolume: false),
                    .copy, "option forces copy across volumes")
    }

    await test("sameVolume detects shared and unknown volumes") {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("m8-drop-\(UUID().uuidString)")
        let a = dir.appendingPathComponent("a")
        let b = dir.appendingPathComponent("b")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        expect(DropDecision.sameVolume(a, b), "two temp dirs share a volume")
        expect(!DropDecision.sameVolume(
                   dir.appendingPathComponent("missing"), b),
               "unreadable source → false (decide() then copies — safe default)")
    }
}
