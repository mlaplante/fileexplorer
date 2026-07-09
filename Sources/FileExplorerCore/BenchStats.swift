import Foundation

/// Pure helpers for the FileExplorerBench harness: median, the stable
/// machine-readable output line, and baseline comparison. Kept in Core so
/// the test harness can exercise them (executables can't be imported).
public enum BenchStats {
    /// Median of samples; 0 for empty input by contract (a scenario that
    /// produced no samples reports 0 rather than crashing the run).
    public static func median(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Stable machine-readable line: `bench:<scenario> median_ms=<n> runs=<n>`.
    /// One decimal place keeps diffs readable; parsing tolerates any decimals.
    public static func line(scenario: String, medianMS: Double, runs: Int) -> String {
        String(format: "bench:%@ median_ms=%.1f runs=%d", scenario, medianMS, runs)
    }

    public static func parse(line: String) -> (scenario: String, medianMS: Double)? {
        guard line.hasPrefix("bench:") else { return nil }
        let parts = line.dropFirst("bench:".count)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let msPart = parts.first(where: { $0.hasPrefix("median_ms=") }),
              let ms = Double(msPart.dropFirst("median_ms=".count))
        else { return nil }
        return (String(parts[0]), ms)
    }

    /// Positive = regression, negative = improvement. Zero baseline → 0
    /// (comparison is meaningless; don't divide by zero).
    public static func deltaPercent(baseline: Double, current: Double) -> Double {
        guard baseline > 0 else { return 0 }
        return (current - baseline) / baseline * 100
    }
}
