import Foundation
import FileExplorerCore

@MainActor
func renamePlanTests() async {
    func url(_ name: String) -> URL { URL(fileURLWithPath: "/t/\(name)") }

    await test("find/replace, prefix, suffix operate on the basename only") {
        var rules = RenameRules()
        rules.find = "IMG"
        rules.replace = "Photo"
        rules.prefix = "2026-"
        rules.suffix = "-web"
        let items = RenamePlan.plan(urls: [url("IMG_001.jpg")], rules: rules,
                                    existingNames: [])
        expectEqual(items[0].newName, "2026-Photo_001-web.jpg",
                    "basename transformed, extension preserved")
        expect(items[0].conflict == nil, "no conflict")
    }

    await test("numbering appends padded sequence after other rules") {
        var rules = RenameRules()
        rules.numbering = true
        rules.numberStart = 9
        rules.numberPadding = 3
        let items = RenamePlan.plan(urls: [url("a.png"), url("b.png")],
                                    rules: rules, existingNames: [])
        expectEqual(items.map(\.newName), ["a-009.png", "b-010.png"],
                    "padded, sequential, before extension")
    }

    await test("conflicts: duplicate targets, existing files, invalid names") {
        var rules = RenameRules()
        rules.find = "x"
        rules.replace = "same"
        let dupes = RenamePlan.plan(urls: [url("x1.txt"), url("x1.txt")],
                                    rules: rules, existingNames: [])
        // identical sources → identical targets → both flagged duplicate
        expect(dupes.allSatisfy { $0.conflict == .duplicateTarget },
               "duplicate targets flagged")

        var clash = RenameRules()
        clash.prefix = "new-"
        let existing = RenamePlan.plan(urls: [url("file.txt")], rules: clash,
                                       existingNames: ["new-file.txt"])
        expectEqual(existing[0].conflict, .existingFile, "existing name flagged")

        var bad = RenameRules()
        bad.replace = "a/b"
        bad.find = "file"
        let invalid = RenamePlan.plan(urls: [url("file.txt")], rules: bad,
                                      existingNames: [])
        expectEqual(invalid[0].conflict, .invalidName, "slash flagged invalid")
    }

    await test("unchanged names are marked so apply can skip them") {
        let rules = RenameRules()   // no-op rules
        let items = RenamePlan.plan(urls: [url("keep.txt")], rules: rules,
                                    existingNames: ["keep.txt"])
        expectEqual(items[0].newName, "keep.txt", "name unchanged")
        expectEqual(items[0].conflict, .unchanged,
                    "unchanged flagged (not existingFile, even though it exists)")
    }

    await test("plan allows targets vacated by the batch, blocks outside holders") {
        let a = URL(fileURLWithPath: "/t/a.txt")
        let ax = URL(fileURLWithPath: "/t/ax.txt")
        var rules = RenameRules()
        rules.suffix = "x"

        let plan = RenamePlan.plan(urls: [a, ax], rules: rules,
                                   existingNames: ["a.txt", "ax.txt"])
        expectEqual(plan[0].newName, "ax.txt", "suffix applied to first item")
        expect(plan[0].conflict == nil,
               "in-batch vacated name is not a conflict")
        expectEqual(plan[1].newName, "axx.txt", "second item moves away")
        expect(plan[1].conflict == nil, "vacating item itself is clean")

        // Same target, but the holder is NOT in the batch → still blocked.
        let blocked = RenamePlan.plan(urls: [a], rules: rules,
                                      existingNames: ["a.txt", "ax.txt"])
        expectEqual(blocked[0].conflict, .existingFile,
                    "outside-holder target stays blocked")
    }

    await test("vacated set excludes conflicted vacators (no execute-time surprises)") {
        // E→L.txt is only legal if L.txt actually moves; here L→C.txt is
        // blocked because C's own proposal is a duplicate-target skip.
        let e = URL(fileURLWithPath: "/t/E.txt")
        let l = URL(fileURLWithPath: "/t/L.txt")
        let c = URL(fileURLWithPath: "/t/C.txt")
        // Build rules-free expectations via direct plan invocation: use rules
        // that produce these names. find/replace: E→L, L→C, C→D is not
        // expressible in one rules pass — so instead assert through the
        // fixpoint directly with a two-item chain that IS expressible:
        // suffix "x" on [a.txt, ax.txt] with an OUTSIDE holder axx.txt:
        // ax.txt→axx.txt is .existingFile (axx.txt exists outside the batch),
        // so ax.txt never vacates, so a.txt→ax.txt must ALSO be .existingFile.
        var rules = RenameRules()
        rules.suffix = "x"
        let a = URL(fileURLWithPath: "/t/a.txt")
        let ax = URL(fileURLWithPath: "/t/ax.txt")
        let chain = RenamePlan.plan(urls: [a, ax], rules: rules,
                                    existingNames: ["a.txt", "ax.txt", "axx.txt"])
        expectEqual(chain[1].conflict, .existingFile,
                    "vacator blocked by outside holder")
        expectEqual(chain[0].conflict, .existingFile,
                    "dependent item blocked too — its target never vacates")
        _ = (e, l, c)
    }
}
