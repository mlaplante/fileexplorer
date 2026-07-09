import Foundation
import FileExplorerCore

@MainActor
func benchStatsTests() async {
    await test("BenchStats.median handles odd, even, and empty inputs") {
        expectEqual(BenchStats.median([3, 1, 2]), 2, "odd count picks middle")
        expectEqual(BenchStats.median([4, 1, 3, 2]), 2.5, "even count averages middles")
        expectEqual(BenchStats.median([]), 0, "empty input is 0 by contract")
        expectEqual(BenchStats.median([7]), 7, "single sample is itself")
    }

    await test("BenchStats line format round-trips") {
        let line = BenchStats.line(scenario: "directory-load", medianMS: 123.456, runs: 5)
        expectEqual(line, "bench:directory-load median_ms=123.5 runs=5",
                    "machine line format is stable")
        let parsed = BenchStats.parse(line: line)
        expectEqual(parsed?.scenario, "directory-load", "scenario parses back")
        expectEqual(parsed?.medianMS, 123.5, "median parses back")
        expect(BenchStats.parse(line: "not a bench line") == nil,
               "non-bench lines parse to nil")
    }

    await test("BenchStats.deltaPercent compares against a baseline") {
        expectEqual(BenchStats.deltaPercent(baseline: 100, current: 150), 50,
                    "50% regression")
        expectEqual(BenchStats.deltaPercent(baseline: 100, current: 80), -20,
                    "20% improvement")
        expectEqual(BenchStats.deltaPercent(baseline: 0, current: 10), 0,
                    "zero baseline yields 0 rather than dividing by zero")
    }
}
