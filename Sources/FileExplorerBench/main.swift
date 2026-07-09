// Sources/FileExplorerBench/main.swift
import Foundation
import FileExplorerCore

@MainActor
func runBench() async throws {
    var args = Array(CommandLine.arguments.dropFirst())
    func takeValue(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return value
    }
    let smoke = args.contains("--smoke")
    let runs = Int(takeValue("--runs") ?? "") ?? (smoke ? 2 : 5)
    let only = takeValue("--only")
    let jsonPath = takeValue("--json")
    let comparePath = takeValue("--compare")

    let profile: BenchProfile = smoke ? .smoke : .full
    print("building fixtures (\(profile.name))…")
    let fixtures = try FixtureBuilder.build(profile: profile)

    var results: [String: Double] = [:]
    var failures = 0
    for scenario in Scenarios.all where only == nil || scenario.name == only {
        let median = try await Scenarios.measure(scenario, fixtures: fixtures,
                                                 runs: runs)
        results[scenario.name] = median
        print(BenchStats.line(scenario: scenario.name, medianMS: median,
                              runs: runs))
        if smoke, median > scenario.smokeCapSeconds * 1000 {
            failures += 1
            print("  SMOKE FAIL - \(scenario.name) exceeded "
                + "\(scenario.smokeCapSeconds)s cap")
        }
    }

    if let jsonPath {
        let data = try JSONSerialization.data(
            withJSONObject: results, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: jsonPath))
        print("saved \(jsonPath)")
    }
    if let comparePath {
        guard let data = FileManager.default.contents(atPath: comparePath),
              let baseline = try JSONSerialization.jsonObject(with: data)
                as? [String: Double] else {
            print("ERROR: can't read baseline at \(comparePath)")
            exit(2)
        }
        for (name, current) in results.sorted(by: { $0.key < $1.key }) {
            guard let base = baseline[name] else {
                print("\(name): no baseline")
                continue
            }
            let delta = BenchStats.deltaPercent(baseline: base, current: current)
            print(String(format: "%@: %.1f ms → %.1f ms (%+.1f%%)",
                         name, base, current, delta))
        }
    }
    exit(failures == 0 ? 0 : 1)
}

// Top-level code is MainActor-isolated and supports await in main.swift.
do { try await runBench() } catch {
    print("BENCH ERROR: \(error)")
    exit(2)
}
