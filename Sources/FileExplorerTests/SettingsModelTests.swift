import Foundation
import FileExplorerCore

@MainActor
func settingsModelTests() async {
    await test("SettingsModel loads, updates, persists, and clamps quality") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m8-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)

        let model = SettingsModel(persister: persister)
        expectEqual(model.settings.jpegQuality, 0.85, "defaults on first launch")

        model.setJPEGQuality(0.6)
        expectEqual(model.settings.jpegQuality, 0.6, "update applies in memory")
        expectEqual(persister.loadSettings().jpegQuality, 0.6,
                    "update persists immediately")

        let reloaded = SettingsModel(persister: persister)
        expectEqual(reloaded.settings.jpegQuality, 0.6, "fresh model reads saved value")

        expectEqual(AppSettings(jpegQuality: 7).jpegQuality, 1.0,
                    "quality clamps to 1.0 max")
        expectEqual(AppSettings(jpegQuality: -1).jpegQuality, 0.1,
                    "quality clamps to 0.1 min")
    }

    await test("AppSettings without knownTags key still decodes") {
        let old = #"{"jpegQuality":0.9}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        expectEqual(decoded.jpegQuality, 0.9, "old field intact")
        expectEqual(decoded.knownTags, [], "missing knownTags defaults empty")
        expectEqual(decoded.folderViewSettings, [:],
                    "missing folderViewSettings defaults empty")
        expectEqual(decoded.smartFolders, [],
                    "missing smartFolders defaults empty")
        expectEqual(decoded.terminalAppPath, nil,
                    "missing terminal app path defaults nil")
        expectEqual(decoded.editorAppPath, nil,
                    "missing editor app path defaults nil")
    }

    await test("AppSettings round-trips terminal and editor app paths") {
        let settings = AppSettings(terminalAppPath: "/Applications/iTerm.app",
                                   editorAppPath: "/Applications/Code.app")
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        expectEqual(decoded.terminalAppPath, "/Applications/iTerm.app",
                    "terminal path survives encode/decode")
        expectEqual(decoded.editorAppPath, "/Applications/Code.app",
                    "editor path survives encode/decode")
    }

    await test("SettingsModel persists and clears integration app paths") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)
        let model = SettingsModel(persister: persister)

        model.setTerminalAppPath("/Applications/iTerm.app")
        model.setEditorAppPath("/Applications/Code.app")

        expectEqual(model.settings.terminalAppPath, "/Applications/iTerm.app",
                    "terminal path updates in memory")
        expectEqual(model.settings.editorAppPath, "/Applications/Code.app",
                    "editor path updates in memory")
        expectEqual(persister.loadSettings().terminalAppPath,
                    "/Applications/iTerm.app",
                    "terminal path persists")
        expectEqual(persister.loadSettings().editorAppPath,
                    "/Applications/Code.app",
                    "editor path persists")

        model.setTerminalAppPath(nil)
        model.setEditorAppPath(nil)

        expectEqual(model.settings.terminalAppPath, nil,
                    "terminal path clears in memory")
        expectEqual(model.settings.editorAppPath, nil,
                    "editor path clears in memory")
        expectEqual(persister.loadSettings().terminalAppPath, nil,
                    "terminal path clear persists")
        expectEqual(persister.loadSettings().editorAppPath, nil,
                    "editor path clear persists")
    }

    await test("SettingsModel persists known tags sorted and deduped") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m14-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)
        let model = SettingsModel(persister: persister)

        model.mergeKnownTags(["projx", "Red", "projx", "Blue"])
        expectEqual(model.settings.knownTags, ["Blue", "projx", "Red"],
                    "tags sorted and deduped in memory")
        expectEqual(persister.loadSettings().knownTags, ["Blue", "projx", "Red"],
                    "tags persisted")
    }

    await test("SettingsModel persists folder view settings by standardized path") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m16-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir)
        let model = SettingsModel(persister: persister)
        let folder = dir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        let settings = FolderViewSettings(viewMode: PaneState.ViewMode.icons.rawValue,
                                          groupBy: .kind,
                                          showHidden: true,
                                          sort: [SortToken(field: .modified,
                                                           ascending: false)])

        model.setFolderViewSettings(settings, for: folder)
        expectEqual(model.folderViewSettings(for: folder), settings,
                    "folder settings available in memory")
        expectEqual(persister.loadSettings().folderViewSettings[
            folder.standardizedFileURL.path], settings,
                    "folder settings persisted")
    }

    await test("PaneState applies persisted folder view settings on start") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir.appendingPathComponent("prefs"))
        let model = SettingsModel(persister: persister)
        let folder = dir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: false)
        model.setFolderViewSettings(
            FolderViewSettings(viewMode: PaneState.ViewMode.columns.rawValue,
                               groupBy: .size,
                               showHidden: true,
                               sort: [SortToken(field: .size,
                                                ascending: false)]),
            for: folder)

        let pane = PaneState(url: folder)
        pane.settingsModel = model
        pane.startIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        expectEqual(pane.viewMode, .columns, "view mode restored")
        expectEqual(pane.groupBy, .size, "grouping restored")
        expectEqual(pane.showHidden, true, "hidden setting restored")
        expectEqual(SortTokenCoder.tokens(from: pane.sortOrder),
                    [SortToken(field: .size, ascending: false)],
                    "sort restored")
    }

    await test("SettingsModel saves replaces and deletes workspace profiles") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir.appendingPathComponent("prefs"))
        let model = SettingsModel(persister: persister)
        let snapshot = SessionSnapshot(
            tabs: [SessionSnapshot.Tab(
                panes: [SessionSnapshot.Pane(path: dir.path)],
                activePaneIndex: 0)],
            activeTabIndex: 0)

        model.saveWorkspaceProfile(name: "Work", snapshot: snapshot)
        model.saveWorkspaceProfile(name: "Work", snapshot: snapshot)
        expectEqual(model.settings.workspaceProfiles.map(\.name), ["Work"],
                    "same name replaces")
        expectEqual(persister.loadSettings().workspaceProfiles.map(\.name), ["Work"],
                    "profile persisted")
        model.deleteWorkspaceProfile(name: "Work")
        expectEqual(model.settings.workspaceProfiles, [], "profile deleted")
    }

    await test("SettingsModel saves replaces and deletes smart folders") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persister = SessionPersister(directory: dir.appendingPathComponent("prefs"))
        let model = SettingsModel(persister: persister)
        var filter = FilterState()
        filter.preset = .images

        model.saveSmartFolder(name: "Images", root: dir, filter: filter)
        model.saveSmartFolder(name: "Images", root: dir, filter: filter)
        expectEqual(model.settings.smartFolders.map(\.name), ["Images"],
                    "same name replaces")
        expectEqual(model.settings.smartFolders.first?.rootPath,
                    dir.standardizedFileURL.path,
                    "root path standardized")
        expectEqual(persister.loadSettings().smartFolders.map(\.name), ["Images"],
                    "smart folder persisted")

        model.deleteSmartFolder(name: "Images")
        expectEqual(model.settings.smartFolders, [], "smart folder deleted")
    }
}
