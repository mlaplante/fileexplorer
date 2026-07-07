import Foundation
import FileExplorerCore

@MainActor
func paletteModelTests() async {
    func item(_ title: String) -> PaletteItem {
        PaletteItem(id: title, title: title)
    }

    await test("PaletteModel presents, ranks, and dismisses") {
        let palette = PaletteModel()
        expect(!palette.isPresented, "hidden initially")

        palette.present(mode: .folders)
        expect(palette.isPresented, "presented")
        palette.setItems([item("Documents"), item("Downloads"), item("Music")])
        expectEqual(palette.results.count, 3, "empty query shows all")

        palette.query = "doc"
        expectEqual(palette.results.map(\.title), ["Documents"], "query filters+ranks")
        expectEqual(palette.selectedIndex, 0, "selection resets on query change")

        palette.dismiss()
        expect(!palette.isPresented, "dismissed")
    }

    await test("PaletteModel selection moves and clamps; confirm returns item") {
        let palette = PaletteModel()
        palette.present(mode: .files)
        palette.setItems([item("aa"), item("ab"), item("ac")])
        palette.query = "a"
        palette.moveSelection(1)
        expectEqual(palette.selectedIndex, 1, "down moves")
        palette.moveSelection(10)
        expectEqual(palette.selectedIndex, 2, "clamped at end")
        palette.moveSelection(-10)
        expectEqual(palette.selectedIndex, 0, "clamped at start")
        expectEqual(palette.selection?.title, "aa", "selection resolves")
    }

    await test("PaletteModel presentToken invalidates stale loads") {
        let palette = PaletteModel()
        palette.present(mode: .folders)
        let staleToken = palette.presentToken
        palette.dismiss()
        palette.present(mode: .folders)
        expect(palette.presentToken != staleToken, "token changes per presentation")
        palette.setItems([item("fresh")], token: palette.presentToken)
        expectEqual(palette.results.count, 1, "current-token items accepted")
        palette.setItems([item("stale1"), item("stale2")], token: staleToken)
        expectEqual(palette.results.map(\.title), ["fresh"],
                    "stale-token items ignored")
    }

    await test("PaletteModel caps results at 50") {
        let palette = PaletteModel()
        palette.present(mode: .commands)
        palette.setItems((0..<80).map { item("cmd\($0)") })
        expectEqual(palette.results.count, 50, "cap applied")
    }

    await test("FuzzyCandidate prepared scoring matches string scoring") {
        let candidates = ["Documents", "MyDocs", "dry-oak-cabin", "notes.txt", ""]
        for candidate in candidates {
            let plain = FuzzyMatcher.score(query: "doc", candidate: candidate)
            let prepared = FuzzyMatcher.score(
                queryLowercased: Array("doc"), candidate: FuzzyCandidate(candidate))
            expectEqual(plain, prepared, "prepared == plain for \(candidate)")
        }
    }
}
