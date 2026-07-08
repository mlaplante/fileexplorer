import SwiftUI
import FileExplorerCore
import AppKit

/// Observes NSWorkspace mount/unmount plus ~/Library/CloudStorage changes and
/// republishes the Finder-style Locations list (iCloud, cloud providers,
/// This Mac, external drives, network shares).
/// App-lifetime: owned by FileExplorerApp (stateless view structs must not
/// own @Observable models on this no-@State toolchain).
@MainActor
@Observable
final class LocationsModel {
    private(set) var locations: [Location] = []
    private(set) var ejectableVolumes = Set<URL>()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var cloudWatcher: DispatchSourceFileSystemObject?

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
        watchCloudStorage()
    }

    isolated deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        cloudWatcher?.cancel()
    }

    private static var cloudStorageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }

    private static var icloudDriveURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs",
                                    isDirectory: true)
    }

    /// Installing/removing a File Provider (Dropbox, OneDrive…) writes into
    /// ~/Library/CloudStorage — watch it so the section updates live. Mount
    /// notifications don't fire for File Providers.
    private func watchCloudStorage() {
        let fd = open(Self.cloudStorageURL.path, O_EVTONLY)
        guard fd >= 0 else { return }  // no CloudStorage dir: mounts still refresh
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        cloudWatcher = source
    }

    private func refresh() {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.map { url -> VolumeInfo in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return VolumeInfo(
                url: url,
                name: values?.volumeName ?? url.lastPathComponent,
                isRoot: url.standardizedFileURL.path == "/",
                isInternal: values?.volumeIsInternal ?? false,
                isEjectable: values?.volumeIsEjectable == true
                    || values?.volumeIsRemovable == true,
                isLocal: values?.volumeIsLocal ?? true)
        }

        let fm = FileManager.default
        let cloudFolders = ((try? fm.contentsOfDirectory(
            at: Self.cloudStorageURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? [])
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                    == true
            }
            .map { (name: fm.displayName(atPath: $0.path), url: $0) }

        var isDirectory: ObjCBool = false
        let hasICloud = fm.fileExists(atPath: Self.icloudDriveURL.path,
                                      isDirectory: &isDirectory)
            && isDirectory.boolValue

        locations = LocationsBuilder.build(
            volumes: volumes,
            cloudFolders: cloudFolders,
            icloudURL: hasICloud ? Self.icloudDriveURL : nil)
        ejectableVolumes = Set(locations.filter(\.isEjectable)
            .map { $0.url.standardizedFileURL })
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
    var locationsModel: LocationsModel
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
            Section("Locations") {
                ForEach(locationsModel.locations) { location in
                    row(name: location.name, systemImage: location.systemImage,
                        url: location.url)
                        .contextMenu {
                            if locationsModel.isEjectable(location.url) {
                                Button("Eject") {
                                    locationsModel.eject(location.url,
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
            if !settings.settings.smartFolders.isEmpty {
                Section("Smart Folders") {
                    ForEach(settings.settings.smartFolders) { smartFolder in
                        Button {
                            Task {
                                await session.activePane.applySmartFolder(smartFolder)
                            }
                        } label: {
                            Label(smartFolder.name,
                                  systemImage: "folder.badge.gearshape")
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete Smart Folder") {
                                settings.deleteSmartFolder(name: smartFolder.name)
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
        row(name: place.name, systemImage: place.systemImage, url: place.url)
    }

    private func row(name: String, systemImage: String, url: URL) -> some View {
        let isCurrent = url.standardizedFileURL.path
            == session.activePane.currentURL.path
        return Button {
            Task { await session.activePane.navigate(to: url) }
        } label: {
            Label(name, systemImage: systemImage)
                .fontWeight(isCurrent ? .semibold : .regular)
        }
        .buttonStyle(.plain)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : nil)
    }

    /// Order matters: filter first, then the extensions draft text — the
    /// text field's didSet re-derives filter.extensions (source of truth,
    /// same convention as PaneState.init(snapshot:)).
    private func apply(_ preset: FilterPreset) {
        session.activePane.applyFilter(preset.filter)
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
