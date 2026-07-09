import Foundation
import Observation
import FileExplorerCore

@MainActor
@Observable
final class ScriptsModel {
    private let folder: URL
    private let watcher = DirectoryWatcher()

    private(set) var scripts: [URL] = []

    init(folder: URL = ScriptLister.defaultFolder) {
        self.folder = folder
        refresh()
        watchIfPossible()
    }

    func refresh() {
        scripts = ScriptLister.scripts(in: folder)
    }

    func ensureFolderExistsAndRefresh() throws {
        try ScriptLister.ensureFolderExists(folder)
        refresh()
        watchIfPossible()
    }

    private func watchIfPossible() {
        watcher.watch(folder) { [weak self] in
            self?.refresh()
        }
    }
}
