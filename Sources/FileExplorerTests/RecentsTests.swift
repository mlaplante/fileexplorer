import Foundation
import FileExplorerCore

@MainActor
func recentsTests() async {
    await test("SessionState records navigations as MRU recents") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        let b = dir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)

        let session = SessionState(url: dir)
        await session.activePane.navigate(to: a)
        await session.activePane.navigate(to: b)
        expectEqual(session.recentFolders.map(\.lastPathComponent), ["b", "a"],
                    "most recent first")

        await session.activePane.navigate(to: a)
        expectEqual(session.recentFolders.map(\.lastPathComponent), ["a", "b"],
                    "revisit moves to front without duplicate")
    }

    await test("recents recorded from new tabs and dual panes too") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)

        let session = SessionState(url: dir)
        session.newTab()
        session.activeTab.toggleDual()
        await session.activePane.navigate(to: sub)
        expectEqual(session.recentFolders.first?.lastPathComponent, "sub",
                    "navigation in a dual pane of a new tab is recorded")
    }

    await test("recents are capped at 30") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionState(url: dir)
        for index in 0..<35 {
            let sub = dir.appendingPathComponent("d\(index)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            await session.activePane.navigate(to: sub)
        }
        expectEqual(session.recentFolders.count, 30, "cap enforced")
        expectEqual(session.recentFolders.first?.lastPathComponent, "d34",
                    "newest kept")
    }

    await test("boundary back/forward do not re-record recents") {
        // NOTE on arithmetic: recordRecent() dedupes by removing any existing
        // entry for a URL before reinserting it at the front, so re-recording
        // the *current* URL (which is always already front-of-list right
        // after a real navigation) is a no-op for both count and order --
        // whether or not the boundary call fires onNavigated at all. That
        // makes recentFolders.count unable to distinguish "boundary re-fired
        // onNavigated" from "boundary correctly no-op'd" in this scenario;
        // count stays equal to the snapshot either way (confirmed empirically
        // both with and without the PaneState guard). The real regression
        // coverage for this fix is the onNavigated call-count assertions in
        // "PaneState boundary goBack/goForward do not fire onNavigated"
        // (PaneStateTests.swift), which does discriminate buggy vs. fixed.
        // This test still documents and locks in the correct recents-level
        // semantics: boundary calls never grow or reorder the recents list.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)

        let session = SessionState(url: dir)
        await session.activePane.navigate(to: sub)
        await session.activePane.goBack()
        let snapshot = session.recentFolders
        await session.activePane.goBack()      // boundary no-op
        expectEqual(session.recentFolders, snapshot,
                    "boundary goBack leaves recents unchanged")

        await session.activePane.goForward()
        let afterForward = session.recentFolders
        expectEqual(afterForward.count, snapshot.count,
                    "real goForward re-records the current entry, not a new one")
        await session.activePane.goForward()   // boundary no-op
        expectEqual(session.recentFolders, afterForward,
                    "boundary goForward leaves recents unchanged")
    }

    await test("clearRecentFolders empties recents and snapshot stays empty") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)

        let session = SessionState(url: dir)
        await session.activePane.navigate(to: sub)
        expect(!session.recentFolders.isEmpty, "recent recorded")

        session.clearRecentFolders()
        expect(session.recentFolders.isEmpty, "recents cleared")

        let restored = SessionState(snapshot: session.snapshot(), fallback: dir)
        expect(restored.recentFolders.isEmpty, "snapshot round-trip stays empty")
    }

    await test("recentPlaces caps, excludes, and preserves MRU order") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionState(url: dir)
        var folders: [URL] = []
        for index in 0..<10 {
            let sub = dir.appendingPathComponent("d\(index)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            folders.append(sub)
            await session.activePane.navigate(to: sub)
        }

        let excluded = Set([folders[9].standardizedFileURL.path,
                            folders[4].standardizedFileURL.path])
        let places = session.recentPlaces(limit: 8, excluding: excluded)

        expectEqual(places.count, 8, "limit applied after exclusions")
        expectEqual(places.map { $0.url.standardizedFileURL },
                    [folders[8], folders[7], folders[6], folders[5],
                     folders[3], folders[2], folders[1], folders[0]]
                        .map { $0.standardizedFileURL },
                    "MRU order preserved with exclusions removed")
    }
}
