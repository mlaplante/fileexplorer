import Foundation
import FileExplorerCore

@MainActor
func sessionStateTests() async {
    let home = URL(fileURLWithPath: "/tmp")

    await test("SessionState opens with one tab and adds/selects tabs") {
        let session = SessionState(url: home)
        expectEqual(session.tabs.count, 1, "one tab at launch")
        expectEqual(session.activeTabIndex, 0, "first tab active")

        session.newTab()
        expectEqual(session.tabs.count, 2, "new tab appended")
        expectEqual(session.activeTabIndex, 1, "new tab becomes active")
        expectEqual(session.activeTab.activePane.currentURL,
                    session.tabs[0].activePane.currentURL,
                    "new tab opens at the previous active pane's folder")

        session.selectTab(0)
        expectEqual(session.activeTabIndex, 0, "selectTab switches")
        session.selectTab(9)
        expectEqual(session.activeTabIndex, 0, "out-of-range select ignored")
    }

    await test("SessionState closeTab semantics") {
        let session = SessionState(url: home)
        session.newTab()
        session.newTab()   // 3 tabs, active = 2
        session.closeTab(at: 2)
        expectEqual(session.tabs.count, 2, "tab closed")
        expectEqual(session.activeTabIndex, 1, "active index moves to neighbor")

        session.selectTab(0)
        session.closeTab(at: 1)
        expectEqual(session.activeTabIndex, 0, "closing inactive tab keeps selection")
        expectEqual(session.tabs.count, 1, "one tab left")

        session.closeTab(at: 0)
        expectEqual(session.tabs.count, 1, "closing the last tab is a no-op")
    }

    await test("SessionState activePane tracks tab and pane switches") {
        let session = SessionState(url: home)
        session.activeTab.toggleDual()
        expect(session.activePane === session.activeTab.panes[1],
               "activePane follows dual toggle")
        session.newTab()
        expect(session.activePane === session.tabs[1].panes[0],
               "activePane follows new tab")
    }

    await test("SessionState toggles and dedupes favorite folders") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("favorites-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Pinned")
        let file = root.appendingPathComponent("note.txt")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: file)
        defer { try? fm.removeItem(at: root) }

        let session = SessionState(url: home)
        expect(session.addFavoriteFolder(folder), "folder can be favorited")
        expect(!session.addFavoriteFolder(folder),
               "duplicate favorite is ignored")
        expect(!session.addFavoriteFolder(file),
               "files cannot be added as folder favorites")
        expectEqual(session.favoriteFolders.map(\.path), [folder.standardizedFileURL.path],
                    "one standardized favorite stored")

        session.toggleFavoriteFolder(folder)
        expect(session.favoriteFolders.isEmpty, "toggle removes existing favorite")
        session.toggleFavoriteFolder(folder)
        expect(session.isFavoriteFolder(folder), "toggle adds missing favorite")
    }
}
