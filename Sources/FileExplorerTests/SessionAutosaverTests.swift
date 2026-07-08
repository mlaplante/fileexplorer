import Foundation
import FileExplorerCore

@MainActor
func sessionAutosaverTests() async {
    func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("m7-autosave-\(UUID().uuidString)")
    }

    /// Polls until the saved session satisfies `condition` (or ~2 s passes).
    func waitForSession(
        _ persister: SessionPersister,
        _ condition: @escaping (SessionSnapshot) -> Bool
    ) async -> SessionSnapshot? {
        for _ in 0..<200 {
            if let saved = persister.loadSession(), condition(saved) {
                return saved
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    await test("saveNow writes the current session immediately") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)
        let session = SessionState(url: URL(fileURLWithPath: "/tmp"))
        let autosaver = SessionAutosaver(session: session, persister: persister,
                                         debounceMilliseconds: 10)
        session.newTab()
        autosaver.saveNow()
        expectEqual(persister.loadSession()?.tabs.count, 2,
                    "saveNow persists without waiting for the debounce")
    }

    await test("mutations trigger a debounced save, repeatedly") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)
        let session = SessionState(url: URL(fileURLWithPath: "/tmp"))
        let autosaver = SessionAutosaver(session: session, persister: persister,
                                         debounceMilliseconds: 10)
        autosaver.start()

        session.newTab()
        let first = await waitForSession(persister) { $0.tabs.count == 2 }
        expect(first != nil, "first mutation autosaved")

        // Re-registration after a save: a second mutation must also save.
        session.selectTab(0)
        let second = await waitForSession(persister) { $0.activeTabIndex == 0 }
        expect(second != nil, "observation re-registers after each save")

        // Deep pane mutation reaches the observed snapshot too.
        session.activePane.showHidden = true
        let third = await waitForSession(persister) {
            $0.tabs[0].panes[0].showHidden
        }
        expect(third != nil, "pane-level mutation autosaved")

        // Navigation-only change (history mutation, no other property touched)
        // must also register — currentURL reads the observable history.
        // A genuinely distinct real directory is required: "/private/tmp" is
        // collapsed by `standardizedFileURL` to "/tmp" (its own symlink
        // alias) on macOS, which would leave the pane's path unchanged and
        // make this check vacuous regardless of the expected value.
        let navDir = makeTempDir()
        try? FileManager.default.createDirectory(at: navDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: navDir) }
        let expectedNavPath = navDir.standardizedFileURL.path
        await session.activePane.navigate(to: navDir)
        let fourth = await waitForSession(persister) {
            $0.tabs[0].panes[0].path == expectedNavPath
        }
        expect(fourth != nil, "navigation-only mutation autosaved")
        _ = autosaver   // keep alive through the waits
    }
}
