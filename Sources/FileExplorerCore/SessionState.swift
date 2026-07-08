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
    public private(set) var favoriteFolders: [URL] = []

    public init(url: URL) {
        tabs = []
        tabs = [makeTab(url: url)]
    }

    /// Restore from a saved snapshot; an empty snapshot degrades to the
    /// default single tab at `fallback`.
    public convenience init(snapshot: SessionSnapshot, fallback: URL) {
        self.init(url: fallback)
        restore(snapshot: snapshot, fallback: fallback)
        recentFolders = snapshot.recentFolders.map { URL(fileURLWithPath: $0) }
        favoriteFolders = Self.dedupedFolders(snapshot.favoriteFolders.map {
            URL(fileURLWithPath: $0)
        })
    }

    public func restoreWorkspace(_ profile: WorkspaceProfile, fallback: URL) {
        restore(snapshot: profile.snapshot, fallback: fallback)
    }

    private func restore(snapshot: SessionSnapshot, fallback: URL) {
        if !snapshot.tabs.isEmpty {
            tabs = snapshot.tabs.map { tabSnapshot in
                TabState(snapshot: tabSnapshot, fallback: fallback) {
                    [weak self] visited in
                    self?.recordRecent(visited)
                }
            }
            activeTabIndex = max(0, min(snapshot.activeTabIndex, tabs.count - 1))
        }
    }

    public var activeTab: TabState {
        tabs[min(activeTabIndex, tabs.count - 1)]
    }

    public var activePane: PaneState { activeTab.activePane }

    public func snapshot() -> SessionSnapshot {
        SessionSnapshot(tabs: tabs.map { $0.snapshot() },
                        activeTabIndex: activeTabIndex,
                        recentFolders: recentFolders.map(\.path),
                        favoriteFolders: favoriteFolders.map(\.path))
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

    public func clearRecentFolders() {
        recentFolders.removeAll()
    }

    public func recentPlaces(limit: Int,
                             excluding excludedPaths: Set<String>) -> [StandardPlaces.Place] {
        recentFolders.compactMap { url -> StandardPlaces.Place? in
            let standardized = url.standardizedFileURL
            guard !excludedPaths.contains(standardized.path),
                  Self.isExistingFolder(standardized) else { return nil }
            return StandardPlaces.Place(
                name: FileManager.default.displayName(atPath: standardized.path),
                url: standardized,
                systemImage: "clock")
        }.prefix(limit).map { $0 }
    }

    public func isFavoriteFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return favoriteFolders.contains { $0.standardizedFileURL.path == path }
    }

    @discardableResult
    public func addFavoriteFolder(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard Self.isExistingFolder(standardized),
              !isFavoriteFolder(standardized) else { return false }
        favoriteFolders = favoriteFolders + [standardized]
        return true
    }

    public func removeFavoriteFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        favoriteFolders = favoriteFolders.filter {
            $0.standardizedFileURL.path != path
        }
    }

    public func toggleFavoriteFolder(_ url: URL) {
        if isFavoriteFolder(url) {
            removeFavoriteFolder(url)
        } else {
            _ = addFavoriteFolder(url)
        }
    }

    private static func dedupedFolders(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard isExistingFolder(standardized),
                  seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }

    private static func isExistingFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path,
                                              isDirectory: &isDirectory)
            && isDirectory.boolValue
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
