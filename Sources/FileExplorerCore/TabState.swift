import Foundation
import Observation

/// One browser tab: one or two panes plus which of them is active.
@MainActor
@Observable
public final class TabState: Identifiable {
    public let id = UUID()
    public private(set) var panes: [PaneState]
    public var activePaneIndex = 0
    private let onNavigated: (@MainActor (URL) -> Void)?

    public init(url: URL, onNavigated: (@MainActor (URL) -> Void)? = nil) {
        self.onNavigated = onNavigated
        let pane = PaneState(url: url)
        pane.onNavigated = onNavigated
        panes = [pane]
    }

    public var isDual: Bool { panes.count == 2 }

    public var activePane: PaneState {
        panes[min(activePaneIndex, panes.count - 1)]
    }

    /// Tab-chip label: the active pane's folder name.
    public var title: String {
        let name = activePane.currentURL.lastPathComponent
        return name.isEmpty ? "/" : name
    }

    public func toggleDual() {
        if isDual {
            activePaneIndex = 0
            panes.removeLast()   // PaneState deinit stops its watcher
        } else {
            let pane = PaneState(url: activePane.currentURL)
            pane.onNavigated = onNavigated
            panes.append(pane)
            activePaneIndex = 1
        }
    }
}
