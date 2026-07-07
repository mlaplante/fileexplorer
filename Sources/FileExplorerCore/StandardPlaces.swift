import Foundation

/// The built-in sidebar/⌘G locations: Home plus the standard user folders
/// that actually exist on this machine.
public enum StandardPlaces {
    public struct Place: Identifiable, Hashable, Sendable {
        public let name: String
        public let url: URL
        public let systemImage: String
        public var id: URL { url }

        public init(name: String, url: URL, systemImage: String) {
            self.name = name
            self.url = url
            self.systemImage = systemImage
        }
    }

    public static func favorites() -> [Place] {
        let fm = FileManager.default
        var places = [Place(name: "Home", url: fm.homeDirectoryForCurrentUser,
                            systemImage: "house")]
        let standard: [(String, FileManager.SearchPathDirectory, String)] = [
            ("Desktop", .desktopDirectory, "menubar.dock.rectangle"),
            ("Documents", .documentDirectory, "doc"),
            ("Downloads", .downloadsDirectory, "arrow.down.circle"),
            ("Pictures", .picturesDirectory, "photo"),
        ]
        for (name, directory, icon) in standard {
            if let url = fm.urls(for: directory, in: .userDomainMask).first,
               fm.fileExists(atPath: url.path) {
                places.append(Place(name: name, url: url, systemImage: icon))
            }
        }
        return places
    }
}
