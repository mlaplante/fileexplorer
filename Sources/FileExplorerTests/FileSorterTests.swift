import Foundation
import FileExplorerCore

@MainActor
func fileSorterTests() async {
    func entry(_ name: String, dir: Bool = false, size: Int64 = 0) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/t/\(name)"), name: name,
                  isDirectory: dir, isHidden: false, isSymlink: false,
                  size: size, created: nil, modified: .distantPast, contentType: nil)
    }

    await test("FileSorter sorts by name, folders first") {
        let items = [entry("zebra.txt"), entry("Apple", dir: true), entry("banana.txt")]
        let sorted = FileSorter.sort(items,
            using: [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)])
        expectEqual(sorted.map(\.name), ["Apple", "banana.txt", "zebra.txt"],
                    "folder first, then files by name")
    }

    await test("FileSorter respects descending size") {
        let items = [entry("small", size: 1), entry("big", size: 100), entry("mid", size: 50)]
        let sorted = FileSorter.sort(items,
            using: [KeyPathComparator(\FileEntry.size, order: .reverse)],
            foldersFirst: false)
        expectEqual(sorted.map(\.name), ["big", "mid", "small"], "descending by size")
    }

    await test("FileSorter can disable folders-first") {
        let items = [entry("b", dir: true), entry("a")]
        let sorted = FileSorter.sort(items,
            using: [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)],
            foldersFirst: false)
        expectEqual(sorted.map(\.name), ["a", "b"], "pure name order")
    }

    await test("FileSorter preserves comparator order within each group") {
        let items = [entry("Banana", dir: true), entry("z.txt"),
                     entry("Apple", dir: true), entry("a.txt")]
        let sorted = FileSorter.sort(items,
            using: [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)])
        expectEqual(sorted.map(\.name), ["Apple", "Banana", "a.txt", "z.txt"],
                    "folders sorted among themselves, then files sorted")
    }
}
