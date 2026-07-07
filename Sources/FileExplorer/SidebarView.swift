import SwiftUI
import FileExplorerCore

struct SidebarView: View {
    @Bindable var session: SessionState

    private struct Place: Identifiable, Hashable {
        let name: String
        let url: URL
        let icon: String
        var id: URL { url }
    }

    private var favorites: [Place] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var places = [Place(name: "Home", url: home, icon: "house")]
        let standard: [(String, FileManager.SearchPathDirectory, String)] = [
            ("Desktop", .desktopDirectory, "menubar.dock.rectangle"),
            ("Documents", .documentDirectory, "doc"),
            ("Downloads", .downloadsDirectory, "arrow.down.circle"),
            ("Pictures", .picturesDirectory, "photo"),
        ]
        for (name, dir, icon) in standard {
            if let url = fm.urls(for: dir, in: .userDomainMask).first,
               fm.fileExists(atPath: url.path) {
                places.append(Place(name: name, url: url, icon: icon))
            }
        }
        return places
    }

    private var volumes: [Place] {
        let keys: [URLResourceKey] = [.volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?
                .volumeName ?? url.lastPathComponent
            return Place(name: name, url: url, icon: "externaldrive")
        }
    }

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(favorites) { place in row(place) }
            }
            Section("Volumes") {
                ForEach(volumes) { place in row(place) }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ place: Place) -> some View {
        Button {
            Task { await session.activePane.navigate(to: place.url) }
        } label: {
            Label(place.name, systemImage: place.icon)
        }
        .buttonStyle(.plain)
    }
}
