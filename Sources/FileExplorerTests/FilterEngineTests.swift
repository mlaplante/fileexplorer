import Foundation
import UniformTypeIdentifiers
import FileExplorerCore

@MainActor
func filterEngineTests() async {
    func entry(_ name: String, dir: Bool = false, size: Int64 = 0,
               modified: Date = .distantPast) -> FileEntry {
        let url = URL(fileURLWithPath: "/t/\(name)")
        return FileEntry(url: url, name: name, isDirectory: dir, isHidden: false,
                         isSymlink: false, size: size, created: nil,
                         modified: modified,
                         contentType: dir ? nil : UTType(filenameExtension: url.pathExtension))
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let items = [
        entry("folder", dir: true),
        entry("photo.png", size: 2_000_000, modified: now),
        entry("clip.mp4", size: 200 * 1_048_576, modified: now),
        entry("notes.txt", size: 100, modified: Date(timeIntervalSince1970: 0)),
        entry("paper.pdf", size: 500_000, modified: now),
    ]

    await test("inactive filter passes everything through unchanged") {
        var f = FilterState()
        expect(!f.isActive, "default state is inactive")
        expectEqual(FilterEngine.apply(f, to: items, now: now).count, items.count,
                    "no filtering when inactive")
        f.preset = .images
        expect(f.isActive, "preset activates the filter")
    }

    await test("type preset filters files but folders always pass") {
        var f = FilterState()
        f.preset = .images
        let result = FilterEngine.apply(f, to: items, now: now)
        expectEqual(result.map(\.name).sorted(), ["folder", "photo.png"],
                    "images preset keeps folder + png")
    }

    await test("extension filter matches case-insensitively") {
        var f = FilterState()
        f.extensions = ["pdf", "txt"]
        let result = FilterEngine.apply(f, to: items, now: now)
        expectEqual(result.map(\.name).sorted(), ["folder", "notes.txt", "paper.pdf"],
                    "extension set keeps pdf + txt + folder")
    }

    await test("date and size presets compose with AND semantics") {
        var f = FilterState()
        f.datePreset = .last7Days
        let recent = FilterEngine.apply(f, to: items, now: now)
        expectEqual(recent.map(\.name).sorted(), ["clip.mp4", "folder", "paper.pdf", "photo.png"],
                    "date filter drops the ancient txt")

        f.sizePreset = .over100MB
        let bigRecent = FilterEngine.apply(f, to: items, now: now)
        expectEqual(bigRecent.map(\.name).sorted(), ["clip.mp4", "folder"],
                    "AND of date + size keeps only the big video")

        f.preset = .images
        let none = FilterEngine.apply(f, to: items, now: now)
        expectEqual(none.map(\.name), ["folder"],
                    "no image is over 100MB — only the folder passes")
    }
}
