// Sources/FileExplorerBench/Scenarios.swift
import Foundation
import FileExplorerCore

struct Scenario {
    let name: String
    /// Wall-time cap for --smoke: catches order-of-magnitude blowups, loose
    /// enough that shared-runner jitter never trips it.
    let smokeCapSeconds: Double
    /// MainActor-isolated because DuplicateFinder/UsageScanner are @MainActor
    /// models; the other scenarios don't care where they run.
    let body: @MainActor (FixtureBuilder.Fixtures) async throws -> Void
}

@MainActor
enum Scenarios {
    static let all: [Scenario] = [
        Scenario(name: "directory-load", smokeCapSeconds: 5) { f in
            _ = try DirectoryLoader.load(f.flatRoot, includeHidden: true)
        },
        Scenario(name: "sort-filter", smokeCapSeconds: 5) { f in
            let entries = try DirectoryLoader.load(f.flatRoot, includeHidden: true)
            var filter = FilterState()
            filter.extensions = ["txt", "md"]
            let filtered = FilterEngine.apply(filter, to: entries)
            _ = FileSorter.sort(filtered,
                                using: [KeyPathComparator(\FileEntry.name)])
        },
        Scenario(name: "duplicate-scan", smokeCapSeconds: 60) { f in
            let finder = DuplicateFinder()
            finder.scan(root: f.dupesRoot)
            while finder.isScanning {
                try await Task.sleep(for: .milliseconds(5))
            }
        },
        Scenario(name: "usage-scan", smokeCapSeconds: 60) { f in
            let scanner = UsageScanner()
            scanner.scan(root: f.deepRoot)
            while scanner.isScanning {
                try await Task.sleep(for: .milliseconds(5))
            }
        },
        Scenario(name: "content-scan", smokeCapSeconds: 60) { f in
            _ = ContentScanner.scan(root: f.deepRoot, query: "needle42",
                                    entryCap: 300_000)
        },
        Scenario(name: "archive-parse", smokeCapSeconds: 5) { f in
            _ = ArchiveCatalogParser.parse(listing: f.archiveListing)
        },
    ]

    /// Median wall time in ms over `runs` timed runs after one warm-up.
    static func measure(_ scenario: Scenario,
                        fixtures: FixtureBuilder.Fixtures,
                        runs: Int) async throws -> Double {
        let clock = ContinuousClock()
        try await scenario.body(fixtures)  // warm-up (caches, first-touch IO)
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = clock.now
            try await scenario.body(fixtures)
            let elapsed = clock.now - start
            samples.append(Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15)
        }
        return BenchStats.median(samples)
    }
}
