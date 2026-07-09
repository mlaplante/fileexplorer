import Foundation
import AppKit
import FileExplorerCore

/// Wires palette modes to their data providers and confirm actions.
@MainActor
enum PaletteCoordinator {
    /// Content-search machinery: one searcher app-wide (a new palette
    /// presentation cancels the previous query), debounce so we don't fire
    /// a Spotlight query per keystroke.
    private static let spotlight = SpotlightSearcher()
    private static var debounce: Task<Void, Never>?
    private static let deepScanID = "__deep_scan__"

    static func openFolders(_ palette: PaletteModel, session: SessionState) {
        palette.present(mode: .folders)
        let pane = session.activePane
        palette.targetPane = pane
        let token = palette.presentToken
        let current = pane.currentURL
        let favorites = StandardPlaces.favorites().map(\.url)
        let recents = session.recentFolders
        Task.detached(priority: .userInitiated) {
            let scanned = FolderScanner.subfolders(of: current)
            let ordered = dedupe(favorites + recents + scanned)
            let items = ordered.map { folderItem($0) }
            await palette.setItems(items, token: token)
        }
    }

    static func openFiles(_ palette: PaletteModel, session: SessionState) {
        palette.present(mode: .files)
        let pane = session.activePane
        palette.targetPane = pane
        let token = palette.presentToken
        let current = pane.currentURL
        Task.detached(priority: .userInitiated) {
            let files = FileSearcher.files(under: current)
            let items = files.map {
                PaletteItem(id: $0.path, title: $0.lastPathComponent,
                            subtitle: abbreviate($0.deletingLastPathComponent()))
            }
            await palette.setItems(items, token: token)
        }
    }

    static func openContents(_ palette: PaletteModel, session: SessionState) {
        palette.present(mode: .contents)
        let pane = session.activePane
        palette.targetPane = pane
        let scope = pane.currentURL
        palette.onQueryChange = { term, token in
            debounce?.cancel()
            debounce = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, token == palette.presentToken else { return }
                spotlight.search(term: term, in: scope) { urls in
                    guard token == palette.presentToken else { return }
                    var items = urls.prefix(PaletteModel.maxResults).map {
                        PaletteItem(id: $0.path, title: $0.lastPathComponent,
                                    subtitle: abbreviate($0.deletingLastPathComponent()))
                    }
                    if items.isEmpty, !term.trimmingCharacters(in: .whitespaces).isEmpty {
                        items = [PaletteItem(
                            id: deepScanID,
                            title: "Deep Scan this folder…",
                            subtitle: "Spotlight found nothing — read text files directly")]
                    }
                    palette.setItems(Array(items), token: token)
                }
            }
        }
    }

    private static func runDeepScan(_ palette: PaletteModel, pane: PaneState) {
        let token = palette.presentToken
        let scope = pane.currentURL
        let term = palette.query
        Task.detached(priority: .userInitiated) {
            let urls = ContentScanner.scan(root: scope, query: term)
            let items = urls.map {
                PaletteItem(id: $0.path, title: $0.lastPathComponent,
                            subtitle: abbreviate($0.deletingLastPathComponent()))
            }
            await palette.setItems(items, token: token)
        }
    }

    static func openCommands(_ palette: PaletteModel, session: SessionState,
                             settings: SettingsModel,
                             scriptRunner: ScriptRunner) {
        palette.present(mode: .commands)
        palette.setItems(commands(for: session, settings: settings,
                                  scriptRunner: scriptRunner).map {
            PaletteItem(id: $0.id, title: $0.name, subtitle: $0.shortcut)
        })
    }

    static func confirm(_ item: PaletteItem, palette: PaletteModel,
                        session: SessionState, settings: SettingsModel,
                        scriptRunner: ScriptRunner) {
        // Capture the mode and the palette's opening-time pane before
        // dismiss() clears targetPane — folder/file confirms must land on
        // the pane the palette was opened for, not whatever pane is active
        // now (the user may have switched panes via keyboard while open).
        let mode = palette.mode
        let pane = palette.targetPane ?? session.activePane
        palette.dismiss()
        switch mode {
        case .folders:
            let url = URL(fileURLWithPath: item.id)
            Task { await pane.navigate(to: url) }
        case .files, .contents:
            if item.id == deepScanID {
                // An in-palette action, not a navigation: reopen and swap in
                // scanner results. dismiss() above cleared targetPane and
                // bumped the token — restore the pane so confirming a scan
                // result lands on the pane the palette was opened for, and
                // scan under the CURRENT token so setItems isn't dropped.
                palette.undismiss()
                palette.targetPane = pane
                runDeepScan(palette, pane: pane)
                return
            }
            let url = URL(fileURLWithPath: item.id)
            Task {
                await pane.navigate(to: url.deletingLastPathComponent())
                pane.selection = [url.standardizedFileURL]
            }
        case .commands:
            // Commands intentionally target whatever pane is active at
            // confirm time (e.g. "Toggle Dual Pane" acts on the current tab).
            commands(for: session, settings: settings,
                     scriptRunner: scriptRunner).first { $0.id == item.id }?.action()
        }
    }

    struct AppCommand {
        let id: String
        let name: String
        let shortcut: String
        let action: @MainActor () -> Void
    }

    static func commands(for session: SessionState,
                         settings: SettingsModel,
                         scriptRunner: ScriptRunner) -> [AppCommand] {
        ([
            AppCommand(id: "back", name: "Back", shortcut: "⌘[") {
                Task { await session.activePane.goBack() }
            },
            AppCommand(id: "forward", name: "Forward", shortcut: "⌘]") {
                Task { await session.activePane.goForward() }
            },
            AppCommand(id: "up", name: "Enclosing Folder", shortcut: "⌘↑") {
                Task { await session.activePane.goUp() }
            },
            AppCommand(id: "home", name: "Go Home", shortcut: "⇧⌘H") {
                Task {
                    await session.activePane.navigate(
                        to: FileManager.default.homeDirectoryForCurrentUser)
                }
            },
            AppCommand(id: "newtab", name: "New Tab", shortcut: "⌘T") {
                session.newTab()
            },
            AppCommand(id: "closetab", name: "Close Tab", shortcut: "⌘W") {
                session.closeTab(at: session.activeTabIndex)
            },
            AppCommand(id: "dual", name: "Toggle Dual Pane", shortcut: "⇧⌘D") {
                session.activeTab.toggleDual()
            },
            AppCommand(id: "preview", name: "Preview Pane",
                       shortcut: settings.chord(for: .previewPane).display) {
                session.activeTab.showsPreviewPane.toggle()
            },
            AppCommand(id: "hidden", name: "Toggle Hidden Files", shortcut: "⇧⌘.") {
                session.activePane.showHidden.toggle()
            },
            AppCommand(id: "clearfilters", name: "Clear Filters", shortcut: "") {
                session.activePane.clearFilters()
            },
            AppCommand(id: "reveal", name: "Reveal in Finder", shortcut: "") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [session.activePane.currentURL])
            },
            AppCommand(id: "open-terminal", name: "Open in Terminal",
                       shortcut: settings.chord(for: .openInTerminal).display) {
                guard let path = settings.settings.terminalAppPath else { return }
                let pane = session.activePane
                let target = ScriptInvocationPlanner.terminalTarget(
                    selection: selectedEntries(in: pane),
                    paneFolder: pane.currentURL)
                Task {
                    let result = await AppLauncher.open(urls: [target],
                                                        withAppAt: path)
                    handleAppLaunch(result, kind: "Terminal",
                                    scriptRunner: scriptRunner)
                }
            },
            AppCommand(id: "open-editor", name: "Open in Editor",
                       shortcut: settings.chord(for: .openInEditor).display) {
                guard let path = settings.settings.editorAppPath else { return }
                let pane = session.activePane
                let targets = ScriptInvocationPlanner.editorTargets(
                    selection: selectedEntries(in: pane),
                    paneFolder: pane.currentURL)
                Task {
                    let result = await AppLauncher.open(urls: targets,
                                                        withAppAt: path)
                    handleAppLaunch(result, kind: "Editor",
                                    scriptRunner: scriptRunner)
                }
            },
            AppCommand(id: "open-scripts-folder", name: "Open Scripts Folder",
                       shortcut: "") {
                do {
                    try ScriptLister.ensureFolderExists(ScriptLister.defaultFolder)
                    Task { await session.activePane.navigate(to: ScriptLister.defaultFolder) }
                } catch {
                    scriptRunner.pendingAlert = ScriptResultFormatter.AlertContent(
                        title: "Scripts folder could not be opened",
                        message: String(describing: error))
                }
            },
        ])
        + ScriptLister.scripts(in: ScriptLister.defaultFolder).map { script in
            AppCommand(id: "script:\(script.path)",
                       name: "Run Script: \(script.lastPathComponent)",
                       shortcut: "") {
                let pane = session.activePane
                scriptRunner.run(invocation: ScriptInvocationPlanner.scriptInvocation(
                    script: script,
                    selection: selectedEntries(in: pane),
                    paneFolder: pane.currentURL))
            }
        }
        + settings.settings.filterPresets.map { preset in
            AppCommand(id: "preset:\(preset.name)",
                       name: "Apply Preset: \(preset.name)", shortcut: "") {
                let pane = session.activePane
                pane.filter = preset.filter
                pane.filterExtensionsText = preset.filter.extensions.sorted()
                    .joined(separator: ", ")
            }
        }
    }

    private nonisolated static func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private nonisolated static func folderItem(_ url: URL) -> PaletteItem {
        PaletteItem(id: url.path,
                    title: url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent,
                    subtitle: abbreviate(url.deletingLastPathComponent()))
    }

    private nonisolated static func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private static func selectedEntries(in pane: PaneState) -> [FileEntry] {
        pane.visibleEntries.filter { pane.selection.contains($0.url) }
    }

    private static func handleAppLaunch(_ result: Result<Void, AppLaunchError>,
                                        kind: String,
                                        scriptRunner: ScriptRunner) {
        guard case .failure(let error) = result else { return }
        switch error {
        case .appMissing(let path):
            scriptRunner.pendingAlert = ScriptResultFormatter.AlertContent(
                title: "\(kind) app missing",
                message: "\(path) no longer exists. Open Settings > Integrations to choose another app.")
        case .openFailed(let message):
            scriptRunner.pendingAlert = ScriptResultFormatter.AlertContent(
                title: "\(kind) could not open",
                message: message)
        }
    }
}
