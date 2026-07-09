// Sources/FileExplorerBench/main.swift
import Foundation
import FileExplorerCore

let smoke = CommandLine.arguments.contains("--smoke")
let profile: BenchProfile = smoke ? .smoke : .full
let fixtures = try FixtureBuilder.build(profile: profile)
print("fixtures ready at \(fixtures.flatRoot.deletingLastPathComponent().path)")
