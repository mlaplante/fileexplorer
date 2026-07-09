// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileExplorer",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "FileExplorerCore"),
        .executableTarget(name: "FileExplorer", dependencies: ["FileExplorerCore"]),
        .executableTarget(name: "FileExplorerTests", dependencies: ["FileExplorerCore"]),
        .executableTarget(name: "IconGen"),
        .executableTarget(name: "FileExplorerBench", dependencies: ["FileExplorerCore"]),
    ]
)
