import SwiftUI
import FileExplorerCore
import AppKit

/// Observes NSWorkspace mount/unmount and republishes the volume list.
/// App-lifetime: owned by FileExplorerApp (stateless view structs must not
/// own @Observable models on this no-@State toolchain).
@MainActor
@Observable
final class VolumesModel {
    private(set) var volumes: [StandardPlaces.Place] = []
    private(set) var ejectableVolumes = Set<URL>()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    isolated deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func refresh() {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []
        var ejectable = Set<URL>()
        volumes = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeName ?? url.lastPathComponent
            let isRoot = url.standardizedFileURL.path == "/"
            if !isRoot,
               values?.volumeIsEjectable == true || values?.volumeIsRemovable == true {
                ejectable.insert(url.standardizedFileURL)
            }
            return StandardPlaces.Place(name: name, url: url,
                                        systemImage: "externaldrive")
        }
        ejectableVolumes = ejectable
    }

    func isEjectable(_ url: URL) -> Bool {
        ejectableVolumes.contains(url.standardizedFileURL)
    }

    func eject(_ url: URL, reportingTo pane: PaneState) {
        let name = FileManager.default.displayName(atPath: url.path)
        Task.detached(priority: .userInitiated) {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                await MainActor.run {
                    pane.reportTagFailure("Couldn't eject \(name): \(error.localizedDescription)")
                }
            }
        }
    }
}

struct SidebarView: View {
    @Bindable var session: SessionState
    var volumesModel: VolumesModel
    var settings: SettingsModel

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(favoritePlaces) { place in
                    row(place)
                        .contextMenu {
                            if session.isFavoriteFolder(place.url) {
                                Button("Unfavorite") {
                                    session.removeFavoriteFolder(place.url)
                                }
                            }
                        }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                addDroppedFavorites(urls)
            }
            if !recentPlaces.isEmpty {
                Section("Recents") {
                    ForEach(recentPlaces) { place in
                        row(place)
                    }
                    .contextMenu {
                        Button("Clear Recents") {
                            session.clearRecentFolders()
                        }
                    }
                }
            }
            Section("Volumes") {
                ForEach(volumesModel.volumes) { place in
                    row(place)
                        .contextMenu {
                            if volumesModel.isEjectable(place.url) {
                                Button("Eject") {
                                    volumesModel.eject(place.url,
                                                       reportingTo: session.activePane)
                                }
                            }
                        }
                }
            }
            if !settings.settings.filterPresets.isEmpty {
                Section("Presets") {
                    ForEach(settings.settings.filterPresets) { preset in
                        Button {
                            apply(preset)
                        } label: {
                            Label(preset.name,
                                  systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete Preset") {
                                settings.deletePreset(name: preset.name)
                            }
                        }
                    }
                }
            }
            if !sidebarTags.isEmpty {
                Section("Tags") {
                    ForEach(sidebarTags, id: \.self) { tag in
                        Button {
                            toggleTag(tag)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(TagDotsView.color(for: tag))
                                    .frame(width: 8, height: 8)
                                Text(tag)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var favoritePlaces: [StandardPlaces.Place] {
        let builtIns = StandardPlaces.favorites()
        var seen = Set(builtIns.map { $0.url.standardizedFileURL.path })
        let userPlaces = session.favoriteFolders.compactMap { url -> StandardPlaces.Place? in
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted,
                  isFolder(standardized) else { return nil }
            return StandardPlaces.Place(
                name: FileManager.default.displayName(atPath: standardized.path),
                url: standardized,
                systemImage: "folder")
        }
        return builtIns + userPlaces
    }

    private var builtInFavoritePaths: Set<String> {
        Set(StandardPlaces.favorites().map { $0.url.standardizedFileURL.path })
    }

    private var recentPlaces: [StandardPlaces.Place] {
        session.recentPlaces(limit: 8, excluding: builtInFavoritePaths)
    }

    private var sidebarTags: [String] {
        let labels = NSWorkspace.shared.fileLabels.filter { $0 != "None" }
        let labelSet = Set(labels)
        let extras = settings.settings.knownTags
            .filter { !labelSet.contains($0) }
            .sorted { lhs, rhs in
                let insensitive = lhs.localizedCaseInsensitiveCompare(rhs)
                if insensitive != .orderedSame { return insensitive == .orderedAscending }
                return lhs.localizedCompare(rhs) == .orderedAscending
            }
        return labels + extras
    }

    private func row(_ place: StandardPlaces.Place) -> some View {
        let isCurrent = place.url.standardizedFileURL.path
            == session.activePane.currentURL.path
        return Button {
            Task { await session.activePane.navigate(to: place.url) }
        } label: {
            Label(place.name, systemImage: place.systemImage)
                .fontWeight(isCurrent ? .semibold : .regular)
        }
        .buttonStyle(.plain)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : nil)
    }

    /// Order matters: filter first, then the extensions draft text — the
    /// text field's didSet re-derives filter.extensions (source of truth,
    /// same convention as PaneState.init(snapshot:)).
    private func apply(_ preset: FilterPreset) {
        let pane = session.activePane
        pane.filter = preset.filter
        pane.filterExtensionsText = preset.filter.extensions.sorted()
            .joined(separator: ", ")
    }

    private func toggleTag(_ tag: String) {
        let pane = session.activePane
        if pane.filter.tags == [tag] {
            pane.filter.tags = nil
        } else {
            pane.filter.tags = [tag]
        }
    }

    private func addDroppedFavorites(_ urls: [URL]) -> Bool {
        let folders = urls.filter { isFolder($0) }
        for folder in folders {
            _ = session.addFavoriteFolder(folder)
        }
        return !folders.isEmpty
    }

    private func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path,
                                              isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
