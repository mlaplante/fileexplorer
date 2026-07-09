import Foundation
import FileExplorerCore

@MainActor
func archiveCatalogParserTests() async {
    let calendar = Calendar(identifier: .gregorian)
    let referenceDate = calendar.date(from: DateComponents(
        timeZone: TimeZone(secondsFromGMT: 0), year: 2026, month: 7, day: 9))!

    await test("ArchiveCatalogParser parses files, directories, dates, and spaces") {
        let listing = """
        -rw-r--r--  0 user group    1024 Jul  9 10:30 ./dir/file with spaces.txt
        drwxr-xr-x  0 user group       0 Jul  8  2024 explicit/
        -rw-r--r--  0 user group       5 Bog  1 12:00 weird-date.txt
        -rw-r--r--  0 user group       8 Jul  9  2024 root.txt
        """
        let parsed = ArchiveCatalogParser.parse(listing: listing,
                                                referenceDate: referenceDate)

        expectEqual(parsed.entries.first?.path, "dir/file with spaces.txt",
                    "normalizes ./ prefix and preserves spaces")
        expectEqual(parsed.entries.first?.name, "file with spaces.txt",
                    "file name is last path component")
        expectEqual(parsed.entries.first?.size, 1024, "file size parsed")
        expectEqual(parsed.entries.first?.isDirectory, false, "file is not directory")
        expectEqual(parsed.entries.first?.modified,
                    calendar.date(from: DateComponents(timeZone: TimeZone(secondsFromGMT: 0),
                                                       year: 2026, month: 7, day: 9,
                                                       hour: 10, minute: 30)),
                    "time-shaped date uses reference year")

        let explicit = parsed.entries.first { $0.path == "explicit" }
        expectEqual(explicit?.isDirectory, true, "directory mode/trailing slash parsed")
        expectEqual(explicit?.size, 0, "directory size is zero")
        expectEqual(explicit?.modified,
                    calendar.date(from: DateComponents(timeZone: TimeZone(secondsFromGMT: 0),
                                                       year: 2024, month: 7, day: 8)),
                    "year-shaped date parsed")

        expect(parsed.entries.contains { $0.path == "weird-date.txt" && $0.modified == nil },
               "unparseable date keeps entry with nil modified")
        expectEqual(parsed.hadSuspiciousPaths, false, "ordinary listing has no suspicious paths")
        expectEqual(parsed.isPartial, false, "ordinary listing is not partial")
    }

    await test("ArchiveCatalogParser synthesizes implicit parents once") {
        let listing = """
        -rw-r--r--  0 user group       3 Jul  9 10:30 a/b/c.txt
        drwxr-xr-x  0 user group       0 Jul  9 10:30 a/
        """
        let parsed = ArchiveCatalogParser.parse(listing: listing,
                                                referenceDate: referenceDate)
        let paths = parsed.entries.map(\.path)
        expectEqual(paths.filter { $0 == "a" }.count, 1, "explicit parent is not duplicated")
        expect(paths.contains("a/b"), "missing intermediate parent is synthesized")
        expect(parsed.entries.contains { $0.path == "a/b" && $0.isDirectory },
               "synthesized parent is a directory")
    }

    await test("ArchiveCatalogParser drops unsafe and symlink entries") {
        let listing = """
        -rw-r--r--  0 user group       3 Jul  9 10:30 /etc/passwd
        -rw-r--r--  0 user group       3 Jul  9 10:30 a/../../x
        lrwxr-xr-x  0 user group       7 Jul  9 10:30 link -> target
        -rw-r--r--  0 user group       4 Jul  9 10:30 safe.txt
        """
        let parsed = ArchiveCatalogParser.parse(listing: listing,
                                                referenceDate: referenceDate)
        expectEqual(parsed.entries.map(\.path), ["safe.txt"], "only safe file remains")
        expectEqual(parsed.hadSuspiciousPaths, true, "unsafe paths set the suspicious flag")
    }

    await test("ArchiveCatalogParser caps entries and handles empty listings") {
        let listing = (0..<5).map {
            "-rw-r--r--  0 user group       1 Jul  9 10:30 f\($0).txt"
        }.joined(separator: "\n")
        let parsed = ArchiveCatalogParser.parse(listing: listing, cap: 3,
                                                referenceDate: referenceDate)
        expectEqual(parsed.entries.map(\.path), ["f0.txt", "f1.txt", "f2.txt"],
                    "first cap entries are kept")
        expectEqual(parsed.isPartial, true, "listing over cap is partial")

        let empty = ArchiveCatalogParser.parse(listing: "", referenceDate: referenceDate)
        expectEqual(empty.entries, [], "empty listing has no entries")
        expectEqual(empty.hadSuspiciousPaths, false, "empty listing has no suspicious paths")
        expectEqual(empty.isPartial, false, "empty listing is not partial")
    }
}
