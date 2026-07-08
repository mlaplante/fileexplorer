import Foundation
import FileExplorerCore

private func treeEntry(_ path: String, dir: Bool = false) -> FileEntry {
    FileEntry(url: URL(fileURLWithPath: path),
              name: (path as NSString).lastPathComponent,
              isDirectory: dir, isHidden: false, isSymlink: false,
              size: 0, created: nil, modified: .distantPast,
              contentType: nil)
}

@MainActor
func treeFlattenerTests() async {
    let sub = treeEntry("/root/sub", dir: true)
    let alpha = treeEntry("/root/alpha.txt")
    let bee = treeEntry("/root/sub/bee.txt")
    let nested = treeEntry("/root/sub/nested", dir: true)
    let deep = treeEntry("/root/sub/nested/deep.txt")
    let sortByName: ([FileEntry]) -> [FileEntry] = {
        $0.sorted { $0.name < $1.name }
    }

    await test("TreeFlattener collapsed folders yield roots only") {
        let rows = TreeFlattener.flatten(
            roots: [sub, alpha], children: [:], expanded: [],
            prepare: sortByName)
        expectEqual(rows.map(\.entry.name), ["alpha.txt", "sub"],
                    "prepare orders the root level")
        expectEqual(rows.map(\.depth), [0, 0], "roots sit at depth 0")
    }

    await test("TreeFlattener inlines loaded children under expanded folder") {
        let rows = TreeFlattener.flatten(
            roots: [sub, alpha],
            children: ["/root/sub": [nested, bee]],
            expanded: ["/root/sub"],
            prepare: sortByName)
        expectEqual(rows.map(\.entry.name),
                    ["alpha.txt", "sub", "bee.txt", "nested"],
                    "children follow their folder, sorted per level")
        expectEqual(rows.map(\.depth), [0, 0, 1, 1],
                    "children are one level deeper")
    }

    await test("TreeFlattener key is trailing-slash-insensitive") {
        // contentsOfDirectory yields directory URLs WITH a trailing slash;
        // expansion keyed by standardized path must still match.
        let slashed = FileEntry(url: URL(fileURLWithPath: "/root/sub/",
                                         isDirectory: true),
                                name: "sub", isDirectory: true,
                                isHidden: false, isSymlink: false, size: 0,
                                created: nil, modified: .distantPast,
                                contentType: nil)
        let rows = TreeFlattener.flatten(
            roots: [slashed],
            children: ["/root/sub": [bee]],
            expanded: ["/root/sub"],
            prepare: sortByName)
        expectEqual(rows.map(\.entry.name), ["sub", "bee.txt"],
                    "trailing-slash folder URL still expands")
    }

    await test("TreeFlattener expanded-but-unloaded folder stays collapsed") {
        let rows = TreeFlattener.flatten(
            roots: [sub], children: [:],
            expanded: ["/root/sub"],
            prepare: sortByName)
        expectEqual(rows.count, 1, "no children rows until the load lands")
    }

    await test("TreeFlattener hidden descendants keep their expansion") {
        // nested is expanded and loaded, but its parent sub is NOT expanded:
        // nested's membership must be inert, not an error.
        let children: [String: [FileEntry]] = [
            "/root/sub": [nested, bee],
            "/root/sub/nested": [deep],
        ]
        let rows = TreeFlattener.flatten(
            roots: [sub], children: children,
            expanded: ["/root/sub/nested"],
            prepare: sortByName)
        expectEqual(rows.map(\.entry.name), ["sub"],
                    "collapsed parent hides the whole subtree")
        // Re-expanding the parent restores the nested expansion.
        let restored = TreeFlattener.flatten(
            roots: [sub], children: children,
            expanded: ["/root/sub", "/root/sub/nested"],
            prepare: sortByName)
        expectEqual(restored.map(\.entry.name),
                    ["sub", "bee.txt", "nested", "deep.txt"],
                    "subtree restores when parent re-expands")
        expectEqual(restored.map(\.depth), [0, 1, 1, 2],
                    "depths accumulate through the subtree")
    }

    await test("TreeFlattener per-level prepare filters each level") {
        let onlyTxt: ([FileEntry]) -> [FileEntry] = { level in
            level.filter { $0.isDirectory || $0.name.hasSuffix(".txt") }
                .sorted { $0.name < $1.name }
        }
        let png = treeEntry("/root/sub/pic.png")
        let rows = TreeFlattener.flatten(
            roots: [sub, alpha],
            children: ["/root/sub": [png, bee]],
            expanded: ["/root/sub"],
            prepare: onlyTxt)
        expectEqual(rows.map(\.entry.name), ["alpha.txt", "sub", "bee.txt"],
                    "filter drops png at the child level")
    }

    await test("TreeFlattener guards symlink cycles and depth") {
        // A folder listed as its own child must not recurse forever.
        let loop = treeEntry("/root/loop", dir: true)
        let rows = TreeFlattener.flatten(
            roots: [loop],
            children: ["/root/loop": [loop]],
            expanded: ["/root/loop"],
            prepare: { $0 })
        expectEqual(rows.count, 1, "self-cycle renders one row")

        // Distinct paths nesting past maxDepth stop at the cap.
        var path = "/deep"
        var entries: [FileEntry] = [treeEntry(path, dir: true)]
        var children: [String: [FileEntry]] = [:]
        var expanded = Set<String>()
        for _ in 0..<40 {
            let parent = entries.last!
            path += "/d"
            let child = treeEntry(path, dir: true)
            children[parent.url.standardizedFileURL.path] = [child]
            expanded.insert(parent.url.standardizedFileURL.path)
            entries.append(child)
        }
        let deepRows = TreeFlattener.flatten(
            roots: [entries[0]], children: children, expanded: expanded,
            prepare: { $0 })
        expect(deepRows.count <= TreeFlattener.maxDepth + 1,
               "depth cap bounds the walk [got: \(deepRows.count)]")
    }
}
