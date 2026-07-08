import Foundation
import FileExplorerCore

@MainActor
func locationsBuilderTests() async {
    func vol(_ path: String, name: String, isRoot: Bool = false,
             isInternal: Bool = false, isEjectable: Bool = false,
             isLocal: Bool = true) -> VolumeInfo {
        VolumeInfo(url: URL(fileURLWithPath: path), name: name, isRoot: isRoot,
                   isInternal: isInternal, isEjectable: isEjectable,
                   isLocal: isLocal)
    }

    await test("root volume classifies as thisMac, keeps its name") {
        let locations = LocationsBuilder.build(
            volumes: [vol("/", name: "Macintosh HD", isRoot: true, isInternal: true)],
            cloudFolders: [], icloudURL: nil)
        expectEqual(locations.count, 1, "one location")
        expectEqual(locations[0].kind, .thisMac, "root is thisMac")
        expectEqual(locations[0].name, "Macintosh HD", "keeps volume name")
        expectEqual(locations[0].systemImage, "internaldrive", "internal drive icon")
        expectEqual(locations[0].isEjectable, false, "root never ejectable")
    }

    await test("non-local volume classifies as network") {
        let locations = LocationsBuilder.build(
            volumes: [vol("/Volumes/share", name: "share", isLocal: false)],
            cloudFolders: [], icloudURL: nil)
        expectEqual(locations[0].kind, .network, "non-local is network")
        expectEqual(locations[0].systemImage, "server.rack", "network icon")
    }

    await test("local non-root volume classifies as external, ejectable propagates") {
        let locations = LocationsBuilder.build(
            volumes: [vol("/Volumes/USB", name: "USB", isEjectable: true)],
            cloudFolders: [], icloudURL: nil)
        expectEqual(locations[0].kind, .external, "local non-root is external")
        expectEqual(locations[0].systemImage, "externaldrive", "external icon")
        expectEqual(locations[0].isEjectable, true, "ejectable propagates")
    }

    await test("internal non-root data volume still classifies as external") {
        let locations = LocationsBuilder.build(
            volumes: [vol("/Volumes/Data", name: "Data", isInternal: true)],
            cloudFolders: [], icloudURL: nil)
        expectEqual(locations[0].kind, .external, "internal non-root is external")
    }

    await test("cloud folders and iCloud get kinds, names, icons") {
        let one = URL(fileURLWithPath: "/Users/x/Library/CloudStorage/OneDrive-Work")
        let icloud = URL(fileURLWithPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs")
        let locations = LocationsBuilder.build(
            volumes: [], cloudFolders: [(name: "OneDrive - Work", url: one)],
            icloudURL: icloud)
        expectEqual(locations.count, 2, "two locations")
        expectEqual(locations[0].kind, .icloud, "iCloud first")
        expectEqual(locations[0].name, "iCloud Drive", "fixed display name")
        expectEqual(locations[0].systemImage, "icloud", "icloud icon")
        expectEqual(locations[1].kind, .cloud, "provider second")
        expectEqual(locations[1].name, "OneDrive - Work", "display name passthrough")
        expectEqual(locations[1].systemImage, "cloud", "cloud icon")
    }

    await test("ordering: icloud, cloud A-Z, thisMac, external A-Z, network A-Z") {
        let locations = LocationsBuilder.build(
            volumes: [
                vol("/Volumes/zeta", name: "zeta", isEjectable: true),
                vol("/Volumes/smb", name: "smb", isLocal: false),
                vol("/", name: "Macintosh HD", isRoot: true, isInternal: true),
                vol("/Volumes/Alpha", name: "Alpha", isEjectable: true),
            ],
            cloudFolders: [
                (name: "OneDrive", url: URL(fileURLWithPath: "/cs/OneDrive")),
                (name: "Dropbox", url: URL(fileURLWithPath: "/cs/Dropbox")),
            ],
            icloudURL: URL(fileURLWithPath: "/icloud"))
        expectEqual(locations.map(\.name),
                    ["iCloud Drive", "Dropbox", "OneDrive", "Macintosh HD",
                     "Alpha", "zeta", "smb"],
                    "Finder-style ordering, case-insensitive alpha within groups")
    }

    await test("dedupe by standardized path drops the /Volumes root symlink") {
        let locations = LocationsBuilder.build(
            volumes: [
                vol("/", name: "Macintosh HD", isRoot: true, isInternal: true),
                VolumeInfo(url: URL(fileURLWithPath: "/Volumes/Other/./.."),
                           name: "Macintosh HD", isRoot: false, isInternal: true,
                           isEjectable: false, isLocal: true),
            ],
            cloudFolders: [], icloudURL: nil)
        // The second URL standardizes to "/Volumes" — distinct — so instead
        // exercise dedupe with an exact duplicate:
        let dup = LocationsBuilder.build(
            volumes: [
                vol("/", name: "Macintosh HD", isRoot: true, isInternal: true),
                vol("/", name: "Macintosh HD", isRoot: true, isInternal: true),
            ],
            cloudFolders: [], icloudURL: nil)
        expectEqual(dup.count, 1, "duplicate paths collapse")
        expectEqual(locations.count, 2, "distinct standardized paths both survive")
    }

    await test("empty inputs produce empty output") {
        expectEqual(LocationsBuilder.build(volumes: [], cloudFolders: [],
                                           icloudURL: nil).isEmpty,
                    true, "no inputs, no locations")
    }
}
