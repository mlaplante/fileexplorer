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

    await test("custom date range overrides preset and filters entries") {
        var f = FilterState()
        f.datePreset = .today   // preset alone would pass anything from today
        f.customDateRange = now.addingTimeInterval(-7_200)...now.addingTimeInterval(-3_600)
        let inRange = entry("mid.png", size: 10,
                            modified: now.addingTimeInterval(-5_400))
        let tooNew = entry("new.png", size: 10, modified: now)
        let result = FilterEngine.apply(f, to: [inRange, tooNew], now: now)
        expectEqual(result.map(\.name), ["mid.png"],
                    "custom range wins over the preset")
    }

    await test("custom size range filters entries; folders pass") {
        var f = FilterState()
        f.customSizeRange = Int64(1_000)...Int64(5_000)
        let result = FilterEngine.apply(
            f, to: [entry("dir", dir: true), entry("small.txt", size: 500),
                    entry("mid.txt", size: 3_000), entry("big.txt", size: 10_000)],
            now: now)
        expectEqual(result.map(\.name).sorted(), ["dir", "mid.txt"],
                    "only the in-range file and the folder pass")
    }

    await test("megabytes field parsing clamps overflow and negatives") {
        expectEqual(FilterState.megabytesFieldToBytes("100"), 104_857_600,
                    "plain MB value converts")
        expectEqual(FilterState.megabytesFieldToBytes(" 5 "), 5_242_880,
                    "whitespace trimmed")
        expectEqual(FilterState.megabytesFieldToBytes(""), 0, "empty → 0")
        expectEqual(FilterState.megabytesFieldToBytes("abc"), 0, "garbage → 0")
        expectEqual(FilterState.megabytesFieldToBytes("-5"), 0,
                    "negative clamps to 0")
        expectEqual(FilterState.megabytesFieldToBytes("8796093022208"),
                    (Int64.max / 1_048_576) * 1_048_576,
                    "overflow-scale input clamps instead of trapping")
        expectEqual(FilterState.megabytesFieldToBytes("999999999999999999999999"),
                    0, "beyond-Int64 digits parse to nil → 0")
    }
}
