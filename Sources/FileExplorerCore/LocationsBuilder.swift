import Foundation

/// Finder-style sidebar location kinds, in display order.
public enum LocationKind: Sendable, Hashable {
    case icloud, cloud, thisMac, external, network
}

/// One row in the sidebar's Locations section.
public struct Location: Identifiable, Hashable, Sendable {
    public let kind: LocationKind
    public let name: String
    public let url: URL
    public let isEjectable: Bool
    public var id: URL { url }

    public var systemImage: String {
        switch kind {
        case .icloud: "icloud"
        case .cloud: "cloud"
        case .thisMac: "internaldrive"
        case .external: "externaldrive"
        case .network: "server.rack"
        }
    }

    public init(kind: LocationKind, name: String, url: URL, isEjectable: Bool) {
        self.kind = kind
        self.name = name
        self.url = url
        self.isEjectable = isEjectable
    }
}

/// Raw resource values for one mounted volume — gathered by the app layer
/// so classification stays pure and testable.
public struct VolumeInfo: Sendable {
    public let url: URL
    public let name: String
    public let isRoot: Bool        // standardized path == "/"
    public let isInternal: Bool    // volumeIsInternal ?? false
    public let isEjectable: Bool   // volumeIsEjectable || volumeIsRemovable
    public let isLocal: Bool       // volumeIsLocal ?? true (false ⇒ network)

    public init(url: URL, name: String, isRoot: Bool, isInternal: Bool,
                isEjectable: Bool, isLocal: Bool) {
        self.url = url
        self.name = name
        self.isRoot = isRoot
        self.isInternal = isInternal
        self.isEjectable = isEjectable
        self.isLocal = isLocal
    }
}

/// Pure classification + Finder-style ordering for the Locations section.
public enum LocationsBuilder {
    public static func build(volumes: [VolumeInfo],
                             cloudFolders: [(name: String, url: URL)],
                             icloudURL: URL?) -> [Location] {
        var seen = Set<String>()
        func claim(_ url: URL) -> Bool {
            seen.insert(url.standardizedFileURL.path).inserted
        }

        var icloud: [Location] = []
        if let icloudURL, claim(icloudURL) {
            icloud.append(Location(kind: .icloud, name: "iCloud Drive",
                                   url: icloudURL, isEjectable: false))
        }

        let byName: (Location, Location) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        var cloud: [Location] = []
        for folder in cloudFolders where claim(folder.url) {
            cloud.append(Location(kind: .cloud, name: folder.name,
                                  url: folder.url, isEjectable: false))
        }

        var thisMac: [Location] = []
        var external: [Location] = []
        var network: [Location] = []
        for volume in volumes where claim(volume.url) {
            if volume.isRoot {
                thisMac.append(Location(kind: .thisMac, name: volume.name,
                                        url: volume.url, isEjectable: false))
            } else if !volume.isLocal {
                network.append(Location(kind: .network, name: volume.name,
                                        url: volume.url,
                                        isEjectable: volume.isEjectable))
            } else {
                external.append(Location(kind: .external, name: volume.name,
                                         url: volume.url,
                                         isEjectable: volume.isEjectable))
            }
        }

        return icloud + cloud.sorted(by: byName) + thisMac
            + external.sorted(by: byName) + network.sorted(by: byName)
    }
}
