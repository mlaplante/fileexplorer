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

    /// Restore from a saved snapshot; empty/oversized pane lists and
    /// out-of-range indices are clamped rather than trusted.
    public init(snapshot: SessionSnapshot.Tab, fallback: URL,
                onNavigated: (@MainActor (URL) -> Void)? = nil) {
        self.onNavigated = onNavigated
        let paneSnapshots = snapshot.panes.isEmpty
            ? [SessionSnapshot.Pane(path: fallback.path)]
            : Array(snapshot.panes.prefix(2))
        panes = paneSnapshots.map { paneSnapshot in
            let pane = PaneState(snapshot: paneSnapshot, fallback: fallback)
            pane.onNavigated = onNavigated
            return pane
        }
        activePaneIndex = max(0, min(snapshot.activePaneIndex, panes.count - 1))
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

    public func snapshot() -> SessionSnapshot.Tab {
        SessionSnapshot.Tab(panes: panes.map { $0.snapshot() },
                            activePaneIndex: activePaneIndex)
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
