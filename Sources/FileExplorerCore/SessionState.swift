import Foundation
import Observation

/// The window's tab collection. Tabs are never empty; closing the last tab
/// is a no-op (the window itself is closed with the mouse).
@MainActor
@Observable
public final class SessionState {
    public private(set) var tabs: [TabState]
    public var activeTabIndex = 0

    public init(url: URL) {
        tabs = [TabState(url: url)]
    }

    public var activeTab: TabState {
        tabs[min(activeTabIndex, tabs.count - 1)]
    }

    public var activePane: PaneState { activeTab.activePane }

    /// New tab opens at the current active pane's folder (like Finder/WhimFiles).
    public func newTab() {
        tabs.append(TabState(url: activePane.currentURL))
        activeTabIndex = tabs.count - 1
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
