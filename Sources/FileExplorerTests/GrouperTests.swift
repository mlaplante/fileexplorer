import Foundation
import UniformTypeIdentifiers
import FileExplorerCore

@MainActor
func grouperTests() async {
    func entry(_ name: String, dir: Bool = false, size: Int64 = 0,
               modified: Date = .distantPast) -> FileEntry {
        let url = URL(fileURLWithPath: "/t/\(name)")
        return FileEntry(url: url, name: name, isDirectory: dir, isHidden: false,
                         isSymlink: false, size: size, created: nil,
                         modified: modified,
                         contentType: dir ? nil : UTType(filenameExtension: url.pathExtension))
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    await test("Grouper none returns a single unnamed group preserving input order") {
        let entries = [entry("b.txt"), entry("a.png"), entry("Folder", dir: true)]
        let groups = Grouper.group(entries, by: .none, now: now)
        expectEqual(groups, [FileGroup(title: nil, entries: entries)],
                    "none axis does not regroup entries")
    }

    await test("Grouper kind groups alphabetically with folders first") {
        let folder = entry("Folder", dir: true)
        let png = entry("photo.png")
        let text = entry("notes.txt")
        let groups = Grouper.group([png, folder, text], by: .kind, now: now)
        expectEqual(groups.map(\.title), ["Folder", png.kind, text.kind],
                    "folder group is first, remaining kinds alphabetical")
        expectEqual(groups.flatMap(\.entries).map(\.name),
                    ["Folder", "photo.png", "notes.txt"],
                    "entries stay in their original relative order per group")
    }

    await test("Grouper dateModified buckets newest first and omits empty buckets") {
        let entries = [
            entry("old.txt", modified: now.addingTimeInterval(-40 * 86_400)),
            entry("today.txt", modified: now.addingTimeInterval(-60)),
            entry("week.txt", modified: now.addingTimeInterval(-5 * 86_400)),
            entry("yesterday.txt", modified: now.addingTimeInterval(-86_400)),
            entry("month.txt", modified: now.addingTimeInterval(-20 * 86_400)),
        ]
        let groups = Grouper.group(entries, by: .dateModified, now: now)
        expectEqual(groups.map(\.title),
                    ["Today", "Yesterday", "Previous 7 Days",
                     "Previous 30 Days", "Earlier"],
                    "date buckets use Finder-style recency order")
        expectEqual(groups.map { $0.entries.map(\.name) },
                    [["today.txt"], ["yesterday.txt"], ["week.txt"],
                     ["month.txt"], ["old.txt"]],
                    "date bucket entries preserve incoming order")
    }

    await test("Grouper size buckets largest first with folders separated") {
        let entries = [
            entry("small.txt", size: 512_000),
            entry("huge.mov", size: 2 * 1_073_741_824),
            entry("medium.zip", size: 50 * 1_048_576),
            entry("Folder", dir: true),
            entry("large.dmg", size: 700 * 1_048_576),
        ]
        let groups = Grouper.group(entries, by: .size, now: now)
        expectEqual(groups.map(\.title),
                    [">1 GB", "100 MB-1 GB", "1-100 MB", "0-1 MB", "Folders"],
                    "size buckets are ordered largest first, folders last")
        expectEqual(groups.map { $0.entries.map(\.name) },
                    [["huge.mov"], ["large.dmg"], ["medium.zip"],
                     ["small.txt"], ["Folder"]],
                    "size bucket entries preserve incoming order")
    }

    await test("PaneState derives groupedEntries from filtered sorted visible entries") {
        let pane = PaneState(url: URL(fileURLWithPath: "/tmp"))
        pane.entries = [
            entry("b.txt"),
            entry("a.png"),
            entry("Folder", dir: true),
        ]
        pane.groupBy = .kind
        expectEqual(pane.groupedEntries.flatMap(\.entries).map(\.name),
                    pane.visibleEntries.map(\.name),
                    "pane groups the already-visible ordering")
    }

    await test("SessionSnapshot pane groupBy decodes absent v3-era field as none") {
        let json = """
        {
          "tabs": [{
            "panes": [{
              "path": "/tmp",
              "showHidden": true,
              "viewMode": "icons",
              "filter": {"extensions": []},
              "filterExtensionsText": "",
              "sort": []
            }],
            "activePaneIndex": 0
          }],
          "activeTabIndex": 0,
          "recentFolders": [],
          "favoriteFolders": []
        }
        """
        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self, from: Data(json.utf8))
        expectEqual(decoded.tabs[0].panes[0].groupBy, .none,
                    "old pane snapshots default missing groupBy to none")
    }
}
