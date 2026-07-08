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
        let keys: [URLResourceKey] = [.volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []
        volumes = urls.map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?
                .volumeName ?? url.lastPathComponent
            return StandardPlaces.Place(name: name, url: url,
                                        systemImage: "externaldrive")
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
                ForEach(StandardPlaces.favorites()) { place in row(place) }
            }
            Section("Volumes") {
                ForEach(volumesModel.volumes) { place in row(place) }
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
        }
        .listStyle(.sidebar)
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
}
