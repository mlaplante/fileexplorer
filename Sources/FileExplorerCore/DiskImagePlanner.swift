import Foundation

public struct DiskImageCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String = "/usr/bin/hdiutil",
                arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum DiskImagePlanner {
    public static func createCommand(sourceFolder: URL,
                                     outputDirectory: URL? = nil) -> DiskImageCommand {
        let directory = outputDirectory ?? sourceFolder.deletingLastPathComponent()
        let output = directory.appendingPathComponent(
            sourceFolder.lastPathComponent + ".dmg")
        return DiskImageCommand(arguments: [
            "create",
            "-volname", sourceFolder.lastPathComponent,
            "-srcfolder", sourceFolder.path,
            output.path,
        ])
    }

    public static func attachCommand(image: URL) -> DiskImageCommand {
        DiskImageCommand(arguments: ["attach", image.path])
    }

    public static func detachCommand(volume: URL) -> DiskImageCommand {
        DiskImageCommand(arguments: ["detach", volume.path])
    }

    public static func verifyCommand(image: URL) -> DiskImageCommand {
        DiskImageCommand(arguments: ["verify", image.path])
    }
}
