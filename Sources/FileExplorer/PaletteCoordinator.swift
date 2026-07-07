import Foundation
import AppKit
import FileExplorerCore

/// Wires palette modes to their data providers and confirm actions.
@MainActor
enum PaletteCoordinator {
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

    static func openCommands(_ palette: PaletteModel, session: SessionState) {
        palette.present(mode: .commands)
        palette.setItems(commands(for: session).map {
            PaletteItem(id: $0.id, title: $0.name, subtitle: $0.shortcut)
        })
    }

    static func confirm(_ item: PaletteItem, palette: PaletteModel,
                        session: SessionState) {
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
        case .files:
            let url = URL(fileURLWithPath: item.id)
            Task {
                await pane.navigate(to: url.deletingLastPathComponent())
                pane.selection = [url.standardizedFileURL]
            }
        case .commands:
            // Commands intentionally target whatever pane is active at
            // confirm time (e.g. "Toggle Dual Pane" acts on the current tab).
            commands(for: session).first { $0.id == item.id }?.action()
        }
    }

    struct AppCommand {
        let id: String
        let name: String
        let shortcut: String
        let action: @MainActor () -> Void
    }

    static func commands(for session: SessionState) -> [AppCommand] {
        [
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
            AppCommand(id: "hidden", name: "Toggle Hidden Files", shortcut: "⇧⌘.") {
                session.activePane.showHidden.toggle()
                Task { await session.activePane.reload() }
            },
            AppCommand(id: "clearfilters", name: "Clear Filters", shortcut: "") {
                session.activePane.clearFilters()
            },
            AppCommand(id: "reveal", name: "Reveal in Finder", shortcut: "") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [session.activePane.currentURL])
            },
        ]
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
}
