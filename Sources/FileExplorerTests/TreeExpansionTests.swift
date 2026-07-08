import Foundation
import FileExplorerCore

@MainActor
func treeExpansionTests() async {
    func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-tree-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        let nested = sub.appendingPathComponent("nested")
        try FileManager.default.createDirectory(
            at: nested, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("alpha.txt").path,
            contents: Data())
        FileManager.default.createFile(
            atPath: sub.appendingPathComponent("bee.txt").path,
            contents: Data())
        FileManager.default.createFile(
            atPath: nested.appendingPathComponent("cee.txt").path,
            contents: Data())
        return root
    }

    await test("PaneState expand inlines children; collapse restores") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")

        let pane = PaneState(url: root)
        await pane.reload()
        expectEqual(pane.visibleEntries.map(\.name), ["sub", "alpha.txt"],
                    "root listing before expansion")

        await pane.expand(sub)
        expect(pane.isExpanded(sub), "sub reports expanded")
        expectEqual(pane.visibleEntries.map(\.name),
                    ["sub", "nested", "bee.txt", "alpha.txt"],
                    "children inline after their folder")
        expectEqual(pane.visibleEntries.map { pane.depth(of: $0.url) },
                    [0, 1, 1, 0], "depths exposed per row")
        expectEqual(pane.rootVisibleCount, 2,
                    "root count ignores disclosed rows")

        pane.collapse(sub)
        expectEqual(pane.visibleEntries.map(\.name), ["sub", "alpha.txt"],
                    "collapse restores the root listing")
    }

    await test("PaneState collapse keeps nested expansion (Finder restore)") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")
        let nested = sub.appendingPathComponent("nested")

        let pane = PaneState(url: root)
        await pane.reload()
        await pane.expand(sub)
        await pane.expand(nested)
        expectEqual(pane.visibleEntries.map(\.name),
                    ["sub", "nested", "cee.txt", "bee.txt", "alpha.txt"],
                    "two levels disclosed")
        pane.collapse(sub)
        expectEqual(pane.visibleEntries.map(\.name), ["sub", "alpha.txt"],
                    "collapsing the parent hides the subtree")
        await pane.expand(sub)
        expectEqual(pane.visibleEntries.map(\.name),
                    ["sub", "nested", "cee.txt", "bee.txt", "alpha.txt"],
                    "re-expanding the parent restores nested expansion")
    }

    await test("PaneState collapse folds hidden selection into the folder") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")

        let pane = PaneState(url: root)
        await pane.reload()
        await pane.expand(sub)
        let bee = pane.visibleEntries.first { $0.name == "bee.txt" }!
        pane.selection = [bee.url]
        pane.collapse(sub)
        let subURL = pane.visibleEntries.first { $0.name == "sub" }!.url
        expectEqual(pane.selection, [subURL],
                    "hidden selected descendant becomes the folder selection")
    }

    await test("PaneState reload refreshes children and prunes vanished") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")

        let pane = PaneState(url: root)
        await pane.reload()
        await pane.expand(sub)
        FileManager.default.createFile(
            atPath: sub.appendingPathComponent("dee.txt").path,
            contents: Data())
        await pane.reload()
        expect(pane.visibleEntries.contains { $0.name == "dee.txt" },
               "reload picks up new children of expanded folders")

        try FileManager.default.removeItem(at: sub)
        await pane.reload()
        expect(!pane.isExpanded(sub), "vanished folder loses its expansion")
        expectEqual(pane.visibleEntries.map(\.name), ["alpha.txt"],
                    "no orphan rows after the folder vanished")
    }

    await test("PaneState expandRecursively opens the whole subtree") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")

        let pane = PaneState(url: root)
        await pane.reload()
        await pane.expandRecursively(sub)
        expectEqual(pane.visibleEntries.map(\.name),
                    ["sub", "nested", "cee.txt", "bee.txt", "alpha.txt"],
                    "recursive expand discloses every level")
    }

    await test("PaneState navigation clears tree state") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")

        let pane = PaneState(url: root)
        await pane.reload()
        await pane.expand(sub)
        await pane.navigate(to: sub)
        expect(!pane.isExpanded(sub), "expansion cleared on navigation")
        expectEqual(pane.visibleEntries.map(\.name), ["nested", "bee.txt"],
                    "navigated listing is flat")
    }

    await test("PaneState grouped mode bypasses the tree") {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")

        let pane = PaneState(url: root)
        await pane.reload()
        await pane.expand(sub)
        pane.groupBy = .kind
        expectEqual(pane.visibleEntries.map(\.name).sorted(),
                    ["alpha.txt", "sub"],
                    "grouping renders root level only")
        pane.groupBy = .none
        expect(pane.visibleEntries.contains { $0.name == "bee.txt" },
               "tree returns when grouping is off")
    }
}
