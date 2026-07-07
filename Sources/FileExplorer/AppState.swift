import Foundation
import FileExplorerCore
import Observation

@MainActor
@Observable
final class AppState {
    let pane: PaneState

    init() {
        pane = PaneState(url: FileManager.default.homeDirectoryForCurrentUser)
        pane.start()
        Task { await pane.reload() }
    }
}
