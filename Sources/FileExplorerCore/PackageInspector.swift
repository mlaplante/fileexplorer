import Foundation

public enum PackageInspector {
    private static let knownPackageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "appex", "kext", "rtfd",
        "pages", "numbers", "key", "playground", "xcworkspace", "xcodeproj"
    ]

    public static func isPackage(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isPackageKey]),
           values.isPackage == true {
            return true
        }
        return knownPackageExtensions.contains(url.pathExtension.lowercased())
    }
}
