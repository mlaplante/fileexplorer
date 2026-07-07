import SwiftUI
import FileExplorerCore

struct SidebarView: View {
    @Bindable var session: SessionState

    private var volumes: [StandardPlaces.Place] {
        let keys: [URLResourceKey] = [.volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?
                .volumeName ?? url.lastPathComponent
            return StandardPlaces.Place(name: name, url: url, systemImage: "externaldrive")
        }
    }

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(StandardPlaces.favorites()) { place in row(place) }
            }
            Section("Volumes") {
                ForEach(volumes) { place in row(place) }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ place: StandardPlaces.Place) -> some View {
        Button {
            Task { await session.activePane.navigate(to: place.url) }
        } label: {
            Label(place.name, systemImage: place.systemImage)
        }
        .buttonStyle(.plain)
    }
}
