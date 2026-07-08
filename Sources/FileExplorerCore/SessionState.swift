import Foundation
import Observation

/// The window's tab collection. Tabs are never empty; closing the last tab
/// is a no-op (the window itself is closed with the mouse).
@MainActor
@Observable
public final class SessionState {
    public private(set) var tabs: [TabState]
    public var activeTabIndex = 0

    /// Most-recently-visited folders across all tabs/panes, newest first.
    public private(set) var recentFolders: [URL] = []
    private static let recentsCap = 30

    public init(url: URL) {
        tabs = []
        tabs = [makeTab(url: url)]
    }

    /// Restore from a saved snapshot; an empty snapshot degrades to the
    /// default single tab at `fallback`.
    public convenience init(snapshot: SessionSnapshot, fallback: URL) {
        self.init(url: fallback)
        if !snapshot.tabs.isEmpty {
            tabs = snapshot.tabs.map { tabSnapshot in
                TabState(snapshot: tabSnapshot, fallback: fallback) {
                    [weak self] visited in
                    self?.recordRecent(visited)
                }
            }
            activeTabIndex = max(0, min(snapshot.activeTabIndex, tabs.count - 1))
        }
        recentFolders = snapshot.recentFolders.map { URL(fileURLWithPath: $0) }
    }

    public var activeTab: TabState {
        tabs[min(activeTabIndex, tabs.count - 1)]
    }

    public var activePane: PaneState { activeTab.activePane }

    public func snapshot() -> SessionSnapshot {
        SessionSnapshot(tabs: tabs.map { $0.snapshot() },
                        activeTabIndex: activeTabIndex,
                        recentFolders: recentFolders.map(\.path))
    }

    /// New tab opens at the current active pane's folder (like Finder/WhimFiles).
    public func newTab() {
        tabs.append(makeTab(url: activePane.currentURL))
        activeTabIndex = tabs.count - 1
    }

    private func makeTab(url: URL) -> TabState {
        TabState(url: url) { [weak self] visited in
            self?.recordRecent(visited)
        }
    }

    private func recordRecent(_ url: URL) {
        recentFolders.removeAll { $0 == url }
        recentFolders.insert(url, at: 0)
        if recentFolders.count > Self.recentsCap {
            recentFolders.removeLast(recentFolders.count - Self.recentsCap)
        }
    }

    public func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabIndex = index
    }

    public func closeTab(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        }
    }
}
