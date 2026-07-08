import Foundation
import FileExplorerCore

/// `Bool` isn't `Comparable`, so `KeyPathComparator(\FileEntry.isHidden)`
/// doesn't compile directly. This stand-in lets the "unmapped key path"
/// test build a comparator over `isHidden` without changing what it verifies
/// (that `SortTokenCoder` drops any key path it doesn't recognize).
private struct BoolComparator: SortComparator {
    var order: SortOrder = .forward
    func compare(_ lhs: Bool, _ rhs: Bool) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        let ascending: ComparisonResult = lhs ? .orderedDescending : .orderedAscending
        return order == .forward ? ascending
            : (ascending == .orderedAscending ? .orderedDescending : .orderedAscending)
    }
}

@MainActor
func sessionSnapshotTests() async {
    await test("FilterState round-trips through JSON") {
        var filter = FilterState()
        filter.preset = .images
        filter.extensions = ["png", "jpg"]
        filter.datePreset = .last7Days
        filter.sizePreset = .over100MB
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(FilterState.self, from: data)
        expectEqual(decoded, filter, "filter state survives encode/decode")
    }

    await test("SortTokenCoder maps comparators to tokens and back") {
        var sizeDescending = KeyPathComparator(\FileEntry.size)
        sizeDescending.order = .reverse
        let comparators = [
            KeyPathComparator(\FileEntry.name, comparator: .localizedStandard),
            sizeDescending,
        ]
        let tokens = SortTokenCoder.tokens(from: comparators)
        expectEqual(tokens, [SortToken(field: .name, ascending: true),
                             SortToken(field: .size, ascending: false)],
                    "known key paths map to tokens with direction")

        let restored = SortTokenCoder.comparators(from: tokens)
        expectEqual(restored.count, 2, "both comparators restored")
        expect(restored[0].keyPath == \FileEntry.name, "name key path restored")
        expectEqual(restored[0].order, .forward, "ascending restored")
        expect(restored[1].keyPath == \FileEntry.size, "size key path restored")
        expectEqual(restored[1].order, .reverse, "descending restored")
    }

    await test("SortTokenCoder round-trips kind and modified fields") {
        var modifiedDescending = KeyPathComparator(\FileEntry.modified)
        modifiedDescending.order = .reverse
        let comparators = [
            KeyPathComparator(\FileEntry.kind),
            modifiedDescending,
        ]
        let tokens = SortTokenCoder.tokens(from: comparators)
        expectEqual(tokens, [SortToken(field: .kind, ascending: true),
                             SortToken(field: .modified, ascending: false)],
                    "kind and modified map to tokens")
        let restored = SortTokenCoder.comparators(from: tokens)
        expect(restored[0].keyPath == \FileEntry.kind, "kind key path restored")
        expectEqual(restored[0].order, .forward, "kind ascending restored")
        expect(restored[1].keyPath == \FileEntry.modified, "modified key path restored")
        expectEqual(restored[1].order, .reverse, "modified descending restored")
    }

    await test("SortTokenCoder drops unknown key paths and defaults when empty") {
        let tokens = SortTokenCoder.tokens(
            from: [KeyPathComparator(\FileEntry.isHidden, comparator: BoolComparator())])
        expect(tokens.isEmpty, "unmapped key path dropped")

        let restored = SortTokenCoder.comparators(from: [])
        expectEqual(restored.count, 1, "empty tokens restore a default sort")
        expect(restored[0].keyPath == \FileEntry.name, "default sort is by name")
    }

    await test("snapshot() captures the session graph") {
        let home = URL(fileURLWithPath: "/tmp")
        let session = SessionState(url: home)
        session.activeTab.toggleDual()          // tab 0: dual, right pane active
        session.newTab()                        // tab 1 active
        session.activePane.showHidden = true
        session.activePane.viewMode = .icons
        session.activePane.filter.preset = .images
        session.activePane.filterExtensionsText = "png, jpg"

        let snapshot = session.snapshot()
        expectEqual(snapshot.tabs.count, 2, "two tabs captured")
        expectEqual(snapshot.activeTabIndex, 1, "active tab captured")
        expectEqual(snapshot.tabs[0].panes.count, 2, "dual pane captured")
        expectEqual(snapshot.tabs[0].activePaneIndex, 1, "active pane captured")

        let pane = snapshot.tabs[1].panes[0]
        expectEqual(pane.path, "/tmp", "pane folder captured as path")
        expect(pane.showHidden, "showHidden captured")
        expectEqual(pane.viewMode, "icons", "view mode captured as raw string")
        expectEqual(pane.filter.preset, .images, "filter preset captured")
        expectEqual(pane.filterExtensionsText, "png, jpg",
                    "extension draft text captured")
        expectEqual(pane.sort, [SortToken(field: .name, ascending: true)],
                    "default sort captured as token")
    }

    await test("SessionSnapshot round-trips through JSON") {
        let home = URL(fileURLWithPath: "/tmp")
        let session = SessionState(url: home)
        session.newTab()
        await session.activePane.navigate(to: URL(fileURLWithPath: "/private/tmp"))
        let snapshot = session.snapshot()

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        expectEqual(decoded, snapshot, "snapshot survives encode/decode")
        expect(!decoded.recentFolders.isEmpty, "recents captured via navigation")
    }

    await test("SessionSnapshot decodes minimal JSON with defaults") {
        let json = #"{"tabs":[{"panes":[{"path":"/tmp"}]}]}"#
        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self, from: Data(json.utf8))
        expectEqual(decoded.activeTabIndex, 0, "missing activeTabIndex defaults")
        expectEqual(decoded.tabs[0].activePaneIndex, 0,
                    "missing activePaneIndex defaults")
        let pane = decoded.tabs[0].panes[0]
        expectEqual(pane.path, "/tmp", "path decoded")
        expect(!pane.showHidden, "missing showHidden defaults to false")
        expectEqual(pane.viewMode, "list", "missing viewMode defaults to list")
        expectEqual(pane.filter, FilterState(), "missing filter defaults to empty")
        expect(pane.sort.isEmpty, "missing sort defaults to empty tokens")
        expect(decoded.recentFolders.isEmpty, "missing recents default to empty")
    }

    await test("restore rebuilds the session graph") {
        let home = URL(fileURLWithPath: "/tmp")
        let original = SessionState(url: home)
        original.activeTab.toggleDual()
        original.newTab()
        original.activePane.showHidden = true
        original.activePane.viewMode = .icons
        original.activePane.filter.sizePreset = .under1MB
        original.activePane.filterExtensionsText = "png"
        original.activePane.sortOrder = {
            var c = KeyPathComparator(\FileEntry.modified)
            c.order = .reverse
            return [c]
        }()

        let restored = SessionState(snapshot: original.snapshot(), fallback: home)
        expectEqual(restored.tabs.count, 2, "tabs restored")
        expectEqual(restored.activeTabIndex, 1, "active tab restored")
        expect(restored.tabs[0].isDual, "dual pane restored")
        expectEqual(restored.tabs[0].activePaneIndex, 1, "active pane restored")

        let pane = restored.activePane
        expectEqual(pane.currentURL.path, "/tmp", "pane folder restored")
        expect(pane.showHidden, "showHidden restored")
        expectEqual(pane.viewMode, .icons, "view mode restored")
        expectEqual(pane.filter.sizePreset, .under1MB, "filter restored")
        expectEqual(pane.filter.extensions, ["png"],
                    "extensions re-derived from restored draft text")
        expect(pane.sortOrder[0].keyPath == \FileEntry.modified,
               "sort field restored")
        expectEqual(pane.sortOrder[0].order, .reverse, "sort direction restored")
    }

    await test("restore falls back to nearest existing ancestor") {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("m7-restore-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("kept")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let home = URL(fileURLWithPath: "/tmp")
        let vanished = sub.appendingPathComponent("gone/deeper").path
        let snapshot = SessionSnapshot(tabs: [SessionSnapshot.Tab(
            panes: [SessionSnapshot.Pane(path: vanished)])])
        let restored = SessionState(snapshot: snapshot, fallback: home)
        expectEqual(restored.activePane.currentURL.path,
                    sub.standardizedFileURL.path,
                    "vanished folder falls back to nearest existing ancestor")

        let noAncestors = SessionSnapshot(tabs: [SessionSnapshot.Tab(
            panes: [SessionSnapshot.Pane(path: "")])])
        let fallbackOnly = SessionState(snapshot: noAncestors, fallback: home)
        expectEqual(fallbackOnly.activePane.currentURL.path, "/tmp",
                    "unresolvable path falls back to the fallback URL")
    }

    await test("restore clamps indices and survives empty snapshots") {
        let home = URL(fileURLWithPath: "/tmp")
        var snapshot = SessionSnapshot(tabs: [
            SessionSnapshot.Tab(panes: [SessionSnapshot.Pane(path: "/tmp")],
                                activePaneIndex: 7)],
            activeTabIndex: 9)
        let restored = SessionState(snapshot: snapshot, fallback: home)
        expectEqual(restored.activeTabIndex, 0, "out-of-range tab index clamped")
        expectEqual(restored.tabs[0].activePaneIndex, 0,
                    "out-of-range pane index clamped")

        snapshot = SessionSnapshot(tabs: [])
        let empty = SessionState(snapshot: snapshot, fallback: home)
        expectEqual(empty.tabs.count, 1, "empty snapshot yields one default tab")
        expectEqual(empty.activePane.currentURL.path, "/tmp",
                    "default tab opens at fallback")

        let recents = SessionSnapshot(
            tabs: [SessionSnapshot.Tab(panes: [SessionSnapshot.Pane(path: "/tmp")])],
            recentFolders: ["/tmp", "/private"])
        let withRecents = SessionState(snapshot: recents, fallback: home)
        expectEqual(withRecents.recentFolders.map(\.path), ["/tmp", "/private"],
                    "recent folders restored in order")
    }

    await test("FilterState with custom ranges round-trips; old JSON still decodes") {
        var filter = FilterState()
        filter.customSizeRange = Int64(1)...Int64(2)
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(FilterState.self, from: data)
        expectEqual(decoded, filter, "custom ranges survive encode/decode")

        let legacy = #"{"extensions":[]}"#   // pre-M8 filter JSON, no range keys
        let old = try JSONDecoder().decode(FilterState.self, from: Data(legacy.utf8))
        expect(old.customDateRange == nil && old.customSizeRange == nil,
               "old session.json filters decode with nil custom ranges")
    }
}
