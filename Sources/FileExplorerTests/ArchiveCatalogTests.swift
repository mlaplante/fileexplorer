import Foundation
import FileExplorerCore

@MainActor
func archiveCatalogTests() async {
    func fixtureCatalog() -> ArchiveCatalog {
        let entries = [
            ArchiveEntry(path: "zeta.txt", name: "zeta.txt", isDirectory: false,
                         size: 4, modified: nil),
            ArchiveEntry(path: "docs/readme.md", name: "readme.md", isDirectory: false,
                         size: 8, modified: nil),
            ArchiveEntry(path: "docs", name: "docs", isDirectory: true,
                         size: 0, modified: nil),
            ArchiveEntry(path: "Apps", name: "Apps", isDirectory: true,
                         size: 0, modified: nil),
            ArchiveEntry(path: "docs/images/logo.png", name: "logo.png",
                         isDirectory: false, size: 16, modified: nil),
            ArchiveEntry(path: "docs/images", name: "images", isDirectory: true,
                         size: 0, modified: nil),
            ArchiveEntry(path: "alpha.txt", name: "alpha.txt", isDirectory: false,
                         size: 2, modified: nil),
        ]
        return ArchiveCatalog(parsed: ParsedCatalog(entries: entries,
                                                    hadSuspiciousPaths: true,
                                                    isPartial: true))
    }

    await test("ArchiveCatalog returns sorted root and nested children") {
        let catalog = fixtureCatalog()
        expectEqual(catalog.children(of: "").map(\.path),
                    ["Apps", "docs", "alpha.txt", "zeta.txt"],
                    "root children are folders-first then name sorted")
        expectEqual(catalog.children(of: "docs").map(\.path),
                    ["docs/images", "docs/readme.md"],
                    "nested children are immediate only and sorted")
        expectEqual(catalog.children(of: "docs/images").map(\.path),
                    ["docs/images/logo.png"], "deep folder children resolve")
        expectEqual(catalog.hadSuspiciousPaths, true, "suspicious flag is preserved")
        expectEqual(catalog.isPartial, true, "partial flag is preserved")
    }

    await test("ArchiveCatalog resolves entries by path") {
        let catalog = fixtureCatalog()
        expectEqual(catalog.entry(at: "docs/readme.md")?.name, "readme.md",
                    "nested lookup resolves")
        expectEqual(catalog.entry(at: "missing"), nil, "unknown lookup is nil")
    }

    await test("ArchiveCatalog returns descendant files") {
        let catalog = fixtureCatalog()
        expectEqual(catalog.descendantFiles(of: "docs").map(\.path),
                    ["docs/images/logo.png", "docs/readme.md"],
                    "folder descendants are recursive files only")
        expectEqual(catalog.descendantFiles(of: "zeta.txt").map(\.path),
                    ["zeta.txt"], "file descendant is itself")
        expectEqual(catalog.descendantFiles(of: "missing"), [],
                    "unknown descendant list is empty")
        expectEqual(catalog.fileCount, 4, "fileCount counts non-directories")
    }
}
