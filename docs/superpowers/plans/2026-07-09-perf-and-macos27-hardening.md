# Performance Pass + macOS 27 Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a benchmark harness, land measured performance fixes in FileExplorerCore, and harden the app for macOS 27 without bumping the macOS 15 deployment target.

**Architecture:** New `FileExplorerBench` executable target mirrors the existing `FileExplorerTests` harness pattern (plain executable — no XCTest on the CLT-only toolchain). Timing/statistics helpers live in `FileExplorerCore` so the existing test harness can unit-test them. Perf fixes touch `DirectoryLoader`, `FileHasher`, and `DuplicateFinder` only where a recorded baseline proves a win. M2 is audit + drift tests + CI, no behavior changes.

**Tech Stack:** Swift 6 (swift-tools 6.0), SwiftPM, CryptoKit, GitHub Actions (pinned `macos-26` runner).

**Constraints to keep in mind while executing:**
- No Xcode: build/test with `swift build` / `swift run`. Tests are `swift run FileExplorerTests`, exit code 0 = pass.
- All tests are `@MainActor` functions registered in `Sources/FileExplorerTests/main.swift`; assertions via `expect`/`expectEqual` from `Harness.swift`.
- The repo pattern: small focused files, doc comments explain contracts, no trailing-comment noise.
- Every perf commit message must include before/after benchmark numbers.

---

## Milestone 1 — Benchmark harness + core performance

### Task 1: BenchStats helpers in FileExplorerCore

Pure statistics/format helpers, placed in Core so `FileExplorerTests` can test them (the bench executable can't be imported by the test target).

**Files:**
- Create: `Sources/FileExplorerCore/BenchStats.swift`
- Create: `Sources/FileExplorerTests/BenchStatsTests.swift`
- Modify: `Sources/FileExplorerTests/main.swift` (register `benchStatsTests()`)

- [ ] **Step 1: Write the failing test**

```swift
// Sources/FileExplorerTests/BenchStatsTests.swift
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
```

Register in `Sources/FileExplorerTests/main.swift` — add after `await gitStatusModelTests()`:

```swift
await benchStatsTests()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run FileExplorerTests 2>&1 | tail -5`
Expected: compile error — `BenchStats` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FileExplorerCore/BenchStats.swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run FileExplorerTests 2>&1 | tail -3`
Expected: `PASS (<n> assertions)` where n ≥ 1219.

- [ ] **Step 5: Commit**

```bash
git add Sources/FileExplorerCore/BenchStats.swift Sources/FileExplorerTests/BenchStatsTests.swift Sources/FileExplorerTests/main.swift
git commit -m "feat: BenchStats helpers for the benchmark harness"
```

---

### Task 2: FileExplorerBench target with fixture builder

**Files:**
- Modify: `Package.swift`
- Create: `Sources/FileExplorerBench/FixtureBuilder.swift`
- Create: `Sources/FileExplorerBench/main.swift`

- [ ] **Step 1: Add the target to Package.swift**

```swift
// Package.swift — add to targets array:
        .executableTarget(name: "FileExplorerBench", dependencies: ["FileExplorerCore"]),
```

- [ ] **Step 2: Write FixtureBuilder**

Fixtures are cached under `~/Library/Caches/FileExplorerBench/<profile>-v1/` and reused across runs; a `COMPLETE` stamp marks a finished build so an interrupted generation is rebuilt from scratch. Deterministic content via a seeded LCG — no randomness across runs.

```swift
// Sources/FileExplorerBench/FixtureBuilder.swift
import Foundation

/// Bench fixture profiles. Smoke keeps CI fast; full exercises real scale.
struct BenchProfile {
    let name: String
    let flatFileCount: Int
    let deepEntryCount: Int
    let dupeFileCount: Int
    let archiveLineCount: Int

    static let full = BenchProfile(name: "full", flatFileCount: 50_000,
                                   deepEntryCount: 250_000, dupeFileCount: 2_000,
                                   archiveLineCount: 5_000)
    static let smoke = BenchProfile(name: "smoke", flatFileCount: 2_000,
                                    deepEntryCount: 5_000, dupeFileCount: 200,
                                    archiveLineCount: 1_000)
}

/// Deterministic byte stream (LCG) so fixture content is identical across
/// machines and runs — benchmark inputs must never vary.
struct SeededBytes {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 2_862_933_555_777_941_757 &+ 3037 }
    mutating func next() -> UInt8 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 33)
    }
    mutating func data(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count { bytes[i] = next() }
        return Data(bytes)
    }
}

enum FixtureBuilder {
    struct Fixtures {
        let flatRoot: URL      // flatFileCount small files, one directory
        let deepRoot: URL      // deepEntryCount entries, ~12 levels, text files
        let dupesRoot: URL     // dupeFileCount files, ~30% duplicate ratio
        let archiveListing: String  // synthetic bsdtar -tvf listing
    }

    static func build(profile: BenchProfile) throws -> Fixtures {
        let cachesDir = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask)[0]
        let root = cachesDir.appendingPathComponent(
            "FileExplorerBench/\(profile.name)-v1", isDirectory: true)
        let stamp = root.appendingPathComponent("COMPLETE")
        let fm = FileManager.default

        if !fm.fileExists(atPath: stamp.path) {
            // Partial builds are poison for benchmarks — rebuild from zero.
            try? fm.removeItem(at: root)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try buildFlat(in: root.appendingPathComponent("flat"),
                          count: profile.flatFileCount)
            try buildDeep(in: root.appendingPathComponent("deep"),
                          count: profile.deepEntryCount)
            try buildDupes(in: root.appendingPathComponent("dupes"),
                           count: profile.dupeFileCount)
            try Data().write(to: stamp)
        }
        return Fixtures(
            flatRoot: root.appendingPathComponent("flat"),
            deepRoot: root.appendingPathComponent("deep"),
            dupesRoot: root.appendingPathComponent("dupes"),
            archiveListing: syntheticListing(lineCount: profile.archiveLineCount))
    }

    /// Flat: N files across the common extensions the app resolves types for.
    private static func buildFlat(in dir: URL, count: Int) throws {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let exts = ["txt", "md", "json", "png", "jpg", "pdf", "swift", "log"]
        var rng = SeededBytes(seed: 1)
        for i in 0..<count {
            let url = dir.appendingPathComponent(
                String(format: "file-%06d.%@", i, exts[i % exts.count]))
            try rng.data(count: 64).write(to: url)
        }
    }

    /// Deep: directories fan out 6 wide to depth ~12; every directory gets
    /// text files, one in ~50 containing the content-scan needle.
    private static func buildDeep(in dir: URL, count: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var created = 0
        var queue = [dir]
        var rng = SeededBytes(seed: 2)
        var fileIndex = 0
        while created < count, !queue.isEmpty {
            let parent = queue.removeFirst()
            for d in 0..<6 where created < count {
                let sub = parent.appendingPathComponent("dir-\(created)-\(d)")
                try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                created += 1
                queue.append(sub)
                for f in 0..<8 where created < count {
                    let url = sub.appendingPathComponent("note-\(created)-\(f).txt")
                    fileIndex += 1
                    let needle = fileIndex.isMultiple(of: 50) ? " needle42 " : ""
                    let body = "lorem ipsum\(needle)dolor sit amet\n"
                        + String(decoding: rng.data(count: 128).map {
                            $0 % 26 + 97  // printable ascii keeps files text-like
                        }, as: UTF8.self)
                    try Data(body.utf8).write(to: url)
                    created += 1
                }
            }
        }
    }

    /// Dupes: tiered sizes, ~30% of files are byte-identical copies of a
    /// same-tier original. A "same prefix, different tail" pair per large
    /// tier keeps the prefilter honest.
    private static func buildDupes(in dir: URL, count: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // (size, share of files) — mostly small, a few large.
        let tiers: [(bytes: Int, share: Double)] = [
            (4 * 1024, 0.60), (256 * 1024, 0.30),
            (8 * 1024 * 1024, 0.09), (48 * 1024 * 1024, 0.01),
        ]
        var rng = SeededBytes(seed: 3)
        var index = 0
        for tier in tiers {
            let tierCount = max(2, Int(Double(count) * tier.share))
            var originals: [Data] = []
            for i in 0..<tierCount {
                let url = dir.appendingPathComponent(
                    "dupe-\(tier.bytes)-\(index).bin")
                index += 1
                if i % 10 < 3, let original = originals.last {
                    try original.write(to: url)          // exact duplicate
                } else if i % 10 == 3, let original = originals.last,
                          tier.bytes > 128 * 1024 {
                    var tail = original                   // same 64 KB prefix,
                    tail[tail.count - 1] ^= 0xFF          // different tail
                    try tail.write(to: url)
                } else {
                    let data = rng.data(count: tier.bytes)
                    originals.append(data)
                    try data.write(to: url)
                }
            }
        }
    }

    /// Synthetic bsdtar -tvf listing exercising files, dirs, and spaces.
    private static func syntheticListing(lineCount: Int) -> String {
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for i in 0..<lineCount {
            if i.isMultiple(of: 20) {
                lines.append("drwxr-xr-x  0 user group       0 Jul  8  2024 dir\(i)/")
            } else {
                lines.append("-rw-r--r--  0 user group    \(1000 + i) Jul  9 10:30 dir\(i / 20)/file \(i).txt")
            }
        }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 3: Write a minimal main.swift that builds fixtures and exits**

```swift
// Sources/FileExplorerBench/main.swift
import Foundation
import FileExplorerCore

let smoke = CommandLine.arguments.contains("--smoke")
let profile: BenchProfile = smoke ? .smoke : .full
let fixtures = try FixtureBuilder.build(profile: profile)
print("fixtures ready at \(fixtures.flatRoot.deletingLastPathComponent().path)")
```

- [ ] **Step 4: Build and run smoke fixtures**

Run: `swift run -c release FileExplorerBench --smoke`
Expected: `fixtures ready at …/Library/Caches/FileExplorerBench/smoke-v1` and exit 0. Verify: `ls ~/Library/Caches/FileExplorerBench/smoke-v1` shows `flat deep dupes COMPLETE`.

- [ ] **Step 5: Run existing tests (no regressions), commit**

Run: `swift run FileExplorerTests 2>&1 | tail -2` → `PASS`.

```bash
git add Package.swift Sources/FileExplorerBench/
git commit -m "feat: FileExplorerBench target with deterministic fixtures"
```

---

### Task 3: Bench scenarios and CLI

**Files:**
- Create: `Sources/FileExplorerBench/Scenarios.swift`
- Modify: `Sources/FileExplorerBench/main.swift`

- [ ] **Step 1: Write Scenarios.swift**

```swift
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
```

- [ ] **Step 2: Replace main.swift with the full CLI**

Flags: `--smoke` (small fixtures + caps + runs=2), `--runs N`, `--only <name>`, `--json <path>` (save results), `--compare <path>` (report deltas against a saved run).

```swift
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
```

- [ ] **Step 3: Smoke-run it**

Run: `swift run -c release FileExplorerBench --smoke`
Expected: six `bench:<name> median_ms=… runs=2` lines, exit 0.

- [ ] **Step 4: Commit**

```bash
git add Sources/FileExplorerBench/
git commit -m "feat: bench scenarios, CLI flags, smoke caps"
```

---

### Task 4: Record the full baseline

**Files:**
- Create: `docs/superpowers/plans/2026-07-09-bench-baseline.md` (numbers pasted)
- Baseline JSON stays local (machine-specific): `.build/bench-baseline.json`

- [ ] **Step 1: Run the full profile and save the baseline**

Run: `swift run -c release FileExplorerBench --json .build/bench-baseline.json`
Expected: six bench lines. First run generates ~1 GB of fixtures under `~/Library/Caches/FileExplorerBench/full-v1` and may take several minutes; subsequent runs reuse them.

- [ ] **Step 2: Paste results into the baseline doc**

Create `docs/superpowers/plans/2026-07-09-bench-baseline.md` containing the six `bench:` lines verbatim, the machine description (chip, macOS version via `sw_vers -productVersion`), and the commit hash (`git rev-parse --short HEAD`).

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-07-09-bench-baseline.md
git commit -m "docs: benchmark baseline before perf fixes"
```

---

### Task 5: DirectoryLoader — single resourceValues call per entry

Today `load()` fetches attributes, then makes a second `resourceValues(forKeys: [.contentTypeKey])` call per entry (`DirectoryLoader.swift:40`) — `.contentTypeKey` is not in the prefetched key set, so every entry pays a second metadata round trip.

**Files:**
- Modify: `Sources/FileExplorerCore/DirectoryLoader.swift`

- [ ] **Step 1: Fold `.contentTypeKey` into the single key set**

In `DirectoryLoader.swift` change the key list:

```swift
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        .tagNamesKey, .contentTypeKey,
    ]
```

and replace the second fetch:

```swift
            let contentType = FileContentType.resolve(
                for: url, resourceType: rv.contentType)
```

(the `try?`-wrapped second `resourceValues` call is deleted).

- [ ] **Step 2: Run tests**

Run: `swift run FileExplorerTests 2>&1 | tail -2`
Expected: `PASS`. `directoryLoaderTests` covers type resolution; if any assertion fails, the fix is wrong — stop and investigate rather than adjusting the test.

- [ ] **Step 3: Benchmark the change**

Run: `swift run -c release FileExplorerBench --only directory-load --compare .build/bench-baseline.json`
Expected: `directory-load` delta negative (improvement). Record the numbers.

- [ ] **Step 4: Commit (numbers in message)**

```bash
git add Sources/FileExplorerCore/DirectoryLoader.swift
git commit -m "perf: fetch contentType in DirectoryLoader's single stat

directory-load: <before> ms -> <after> ms (<delta>%) on flat50k"
```

---

### Task 6: FileHasher — prefix hashing

**Files:**
- Modify: `Sources/FileExplorerCore/FileHasher.swift`
- Modify: `Sources/FileExplorerTests/FileHasherTests.swift`

- [ ] **Step 1: Write the failing test** (append inside `fileHasherTests()`)

```swift
    await test("FileHasher prefix hash distinguishes prefix from full content") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hasher-prefix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var shared = Data(repeating: 0xAB, count: 128 * 1024)
        let a = dir.appendingPathComponent("a.bin")
        try shared.write(to: a)
        shared[shared.count - 1] = 0x00  // same first 64 KB, different tail
        let b = dir.appendingPathComponent("b.bin")
        try shared.write(to: b)

        let prefixA = try FileHasher.sha256(of: a, firstBytes: 65_536).get()
        let prefixB = try FileHasher.sha256(of: b, firstBytes: 65_536).get()
        expectEqual(prefixA, prefixB, "identical prefixes hash equal")

        let fullA = try FileHasher.sha256(of: a).get()
        let fullB = try FileHasher.sha256(of: b).get()
        expect(fullA != fullB, "different tails hash differently")

        let capped = try FileHasher.sha256(of: a, firstBytes: 1 << 30).get()
        expectEqual(capped, fullA, "cap beyond file size equals full hash")
    }
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift run FileExplorerTests 2>&1 | tail -3`
Expected: compile error — `sha256(of:firstBytes:)` not defined.

- [ ] **Step 3: Implement by generalizing the existing loop**

Replace `FileHasher`'s body with:

```swift
public enum FileHasher {
    public static func sha256(of url: URL)
        -> Result<String, FileOperationService.FileOpError> {
        sha256(of: url, firstBytes: .max)
    }

    /// Hash of at most the first `limit` bytes. The duplicate scanner uses a
    /// small prefix as a cheap prefilter before committing to full hashes.
    public static func sha256(of url: URL, firstBytes limit: Int)
        -> Result<String, FileOperationService.FileOpError> {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.init("Can't read “\(url.lastPathComponent)”."))
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit
        while remaining > 0 {
            // Explicit do/catch: a thrown read is an error, while a nil or
            // empty chunk is EOF — `try?` would collapse the two.
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: min(remaining, 1_048_576))
            } catch {
                return .failure(.init("Read failed for “\(url.lastPathComponent)”."))
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return .success(hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
```

Keep the existing doc comment about streaming 1 MiB chunks on the type.

- [ ] **Step 4: Run tests to verify pass**

Run: `swift run FileExplorerTests 2>&1 | tail -2` → `PASS`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FileExplorerCore/FileHasher.swift Sources/FileExplorerTests/FileHasherTests.swift
git commit -m "feat: FileHasher prefix hashing for duplicate prefilter"
```

---

### Task 7: DuplicateFinder — prefilter, parallel hashing, sort-at-yield

Three changes to `DuplicateScanRunner.scan` in `Sources/FileExplorerCore/DuplicateFinder.swift`:
1. For size buckets over 128 KB, group by 64 KB prefix hash first; only sub-buckets with ≥2 members get full hashes.
2. Full hashes run in a bounded `withTaskGroup` (width = `min(ProcessInfo.processInfo.activeProcessorCount, 8)`).
3. Stop re-sorting the accumulated `groups` array inside the loop; sort only in the yielded snapshot.

**Files:**
- Modify: `Sources/FileExplorerCore/DuplicateFinder.swift`
- Modify: `Sources/FileExplorerTests/DuplicateFinderTests.swift`

- [ ] **Step 1: Add the prefilter-correctness regression test** (append inside `duplicateFinderTests()`; passes today, guards the prefilter)

```swift
    await test("same-size files with identical prefix but different tail are not duplicates") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dupes-prefix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var content = Data(repeating: 0xCD, count: 256 * 1024)
        try content.write(to: dir.appendingPathComponent("one.bin"))
        content[content.count - 1] ^= 0xFF
        try content.write(to: dir.appendingPathComponent("two.bin"))
        try content.write(to: dir.appendingPathComponent("three.bin"))

        let finder = DuplicateFinder()
        finder.scan(root: dir)
        while finder.isScanning { try await Task.sleep(for: .milliseconds(5)) }

        expectEqual(finder.groups.count, 1, "only the true pair groups")
        expectEqual(finder.groups.first?.members.count, 2,
                    "two/three group; one is excluded despite matching prefix")
    }
```

Run: `swift run FileExplorerTests 2>&1 | tail -2` → `PASS` (baseline behavior).

- [ ] **Step 2: Restructure `DuplicateScanRunner.scan`**

Make it `async` and change the stream factory:

```swift
    static func stream(root: URL, cap: Int) -> AsyncStream<DuplicateScanSnapshot> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await scan(root: root, cap: cap, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
```

Replace the hashing loop (the `for size in bySize.keys.sorted()` block) with:

```swift
        let prefilterThreshold: Int64 = 128 * 1024
        let prefixBytes = 65_536
        var groups: [DuplicateGroup] = []
        for size in bySize.keys.sorted() {
            if Task.isCancelled { break }
            guard let urls = bySize[size], urls.count >= 2 else { continue }

            // Cheap prefilter for large files: same-size-but-different files
            // usually diverge in the first 64 KB, so a prefix hash eliminates
            // them without reading whole files.
            var candidateBuckets: [[URL]]
            if size > prefilterThreshold {
                var byPrefix: [String: [URL]] = [:]
                for url in urls {
                    if Task.isCancelled { break }
                    guard case .success(let prefix) = FileHasher.sha256(
                        of: url, firstBytes: prefixBytes) else { continue }
                    byPrefix[prefix, default: []].append(url)
                }
                candidateBuckets = byPrefix.values.filter { $0.count >= 2 }
            } else {
                candidateBuckets = [urls]
            }

            var byHash: [String: [DuplicateMember]] = [:]
            for bucket in candidateBuckets {
                if Task.isCancelled { break }
                for (url, hash) in await parallelFullHashes(
                    of: bucket.sorted(by: { $0.path < $1.path })) {
                    let modified = (try? url.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate) ?? .distantPast
                    byHash[hash, default: []].append(
                        DuplicateMember(url: url, modified: modified))
                }
            }
            let bucketGroups = byHash.compactMap { hash, members -> DuplicateGroup? in
                guard members.count >= 2 else { return nil }
                return DuplicateGroup(hash: hash, size: size,
                                      members: sortedMembers(members))
            }
            if !bucketGroups.isEmpty {
                groups.append(contentsOf: bucketGroups)
                continuation.yield(snapshot(groups: sortedGroups(groups),
                                            isPartial: isPartial,
                                            scannedFileCount: scannedFileCount,
                                            isFinished: false))
            }
        }
```

Add the bounded parallel hasher below `scan`:

```swift
    /// Full hashes of `urls`, bounded to the core count so a duplicate scan
    /// can't starve the machine. Results keep no particular order; callers
    /// sort members before building groups.
    private static func parallelFullHashes(of urls: [URL]) async -> [(URL, String)] {
        let width = min(ProcessInfo.processInfo.activeProcessorCount, 8)
        var results: [(URL, String)] = []
        var iterator = urls.makeIterator()
        await withTaskGroup(of: (URL, String)?.self) { group in
            for _ in 0..<width {
                guard let url = iterator.next() else { break }
                group.addTask {
                    guard !Task.isCancelled,
                          case .success(let hash) = FileHasher.sha256(of: url)
                    else { return nil }
                    return (url, hash)
                }
            }
            while let finished = await group.next() {
                if let finished { results.append(finished) }
                if let url = iterator.next() {
                    group.addTask {
                        guard !Task.isCancelled,
                              case .success(let hash) = FileHasher.sha256(of: url)
                        else { return nil }
                        return (url, hash)
                    }
                }
            }
        }
        return results
    }
```

The final yield already sorts (`sortedGroups(groups)`) — unchanged.

- [ ] **Step 3: Run tests**

Run: `swift run FileExplorerTests 2>&1 | tail -2`
Expected: `PASS` — every existing duplicate-finder assertion (grouping, ordering, cancellation, cap) plus Step 1's regression test must hold with zero test edits. Any failure means the restructure changed semantics; fix the code, not the test.

- [ ] **Step 4: Benchmark**

Run: `swift run -c release FileExplorerBench --only duplicate-scan --compare .build/bench-baseline.json`
Expected: meaningful improvement (prefilter skips full reads of unique large files; hashing parallelizes). Record numbers.

- [ ] **Step 5: Commit (numbers in message)**

```bash
git add Sources/FileExplorerCore/DuplicateFinder.swift Sources/FileExplorerTests/DuplicateFinderTests.swift
git commit -m "perf: duplicate scan prefix prefilter + bounded parallel hashing

duplicate-scan: <before> ms -> <after> ms (<delta>%) on dupes fixture"
```

---

### Task 8: Full compare run + CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Full before/after comparison**

Run: `swift run -c release FileExplorerBench --compare .build/bench-baseline.json`
Expected: `directory-load` and `duplicate-scan` improved; every other scenario within noise (±10%). If `usage-scan` or `content-scan` regressed, stop — Task 7's task-group pressure may be interfering; investigate before proceeding. Append the after-table to `docs/superpowers/plans/2026-07-09-bench-baseline.md`.

- [ ] **Step 2: Add the CI workflow**

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test-and-bench:
    # Pinned: macos-latest floats between images (see release-binary.yml —
    # v5.1.0 drew macos-15 whose Xcode 16.4 lacks `isolated deinit`).
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4

      - name: Run test harness
        run: swift run FileExplorerTests

      - name: Benchmark smoke (gross-regression gate only)
        run: swift run -c release FileExplorerBench --smoke
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml docs/superpowers/plans/2026-07-09-bench-baseline.md
git commit -m "ci: test harness + benchmark smoke on push/PR"
```

---

## Milestone 2 — macOS 27 compatibility hardening

### Task 9: Deprecation and availability audit

**Files:**
- Modify: whatever the audit surfaces (expected: a handful of files in `Sources/FileExplorer/`)

- [ ] **Step 1: Surface every deprecation warning**

```bash
swift build 2>&1 | grep -iE "deprecat|unavailable|will be removed" | sort -u
```

Also sweep for known-deprecated patterns the compiler may not flag at the macOS 15 target but that macOS 26/27 SDKs deprecate:

```bash
grep -rn --include='*.swift' -E 'NSWorkspace\.shared\.openFile|NSApp\.beginSheet|onChange\(of:.*\)\s*\{\s*\w+ in|\.foregroundColor\(|NavigationView|\.accentColor' Sources/FileExplorer Sources/FileExplorerCore
```

- [ ] **Step 2: Fix each finding by these rules**

- A replacement API exists back to macOS 15 → migrate outright.
- Replacement is macOS 26+ only → keep the old call, wrap the new one in `if #available(macOS 26, *)`, and leave a one-line comment naming the constraint.
- Warning is in test-only code → migrate outright (tests run on the dev machine).
- Never silence with `@available` annotations on callers or blanket warning suppression.

- [ ] **Step 3: Verify and commit**

Run: `swift build 2>&1 | grep -ci deprecat` → expected `0`.
Run: `swift run FileExplorerTests 2>&1 | tail -2` → `PASS`.

```bash
git add -A Sources/
git commit -m "fix: clear deprecation warnings ahead of macOS 27"
```

(If Step 1 finds nothing, commit nothing and note "clean" in the final report.)

---

### Task 10: Strict-concurrency triage

**Files:**
- Modify: whatever the triage surfaces in `Sources/FileExplorerCore/`

- [ ] **Step 1: Build Core with complete checking (triage only — flag is not committed)**

```bash
swift build --target FileExplorerCore -Xswiftc -strict-concurrency=complete 2>&1 | grep -E "warning|error" | sort -u
```

- [ ] **Step 2: Fix real gaps by these rules**

- A type sent across an actor boundary that isn't `Sendable` → make it `Sendable` (value types with `Sendable` members: add conformance; reference types: audit for actual shared mutation first).
- Global mutable state → convert to `let`, or isolate to `@MainActor`.
- Warnings about AppKit types crossing actors in the UI target → out of scope (documented CLT constraints); Core only.
- A warning you can't fix without semantic change → document it in the commit message rather than force-casting with `@unchecked Sendable`.

- [ ] **Step 3: Verify and commit**

Run the Step 1 command again → expected: no Core warnings (or only the documented residue).
Run: `swift run FileExplorerTests 2>&1 | tail -2` → `PASS`.

```bash
git add Sources/FileExplorerCore/
git commit -m "fix: close strict-concurrency gaps in FileExplorerCore"
```

---

### Task 11: Parser drift tests (git + bsdtar)

The app shells out to `/usr/bin/git` (porcelain v2) and `/usr/bin/tar` (bsdtar listing). A macOS 27 toolchain bump must not crash or corrupt parsing when output gains new record types or noise lines.

**Files:**
- Modify: `Sources/FileExplorerTests/GitStatusParserTests.swift`
- Modify: `Sources/FileExplorerTests/ArchiveCatalogParserTests.swift`

- [ ] **Step 1: Add the git drift test** (append inside `gitStatusParserTests()`)

```swift
    await test("GitStatusParser ignores unknown record types and headers (forward compat)") {
        // Porcelain v2, NUL-separated. Record type '3' and header
        // '# stash' don't exist today — simulate a future git.
        let records = [
            "# branch.head main",
            "# stash 5",
            "3 futuristic-record with fields we cannot know",
            "1 .M N... 100644 100644 100644 abc def src/known.swift",
            "? untracked.txt",
            "unparseable garbage line",
        ]
        let data = Data(records.joined(separator: "\u{0}").utf8)
        let status = GitStatusParser.parse(data)

        expectEqual(status.branch, "main", "known headers still parse")
        expectEqual(status.states["src/known.swift"], .modified,
                    "known records still parse")
        expectEqual(status.states["untracked.txt"], .untracked,
                    "untracked records still parse")
        expectEqual(status.states.count, 2,
                    "unknown records add no phantom entries")
    }
```

- [ ] **Step 2: Add the bsdtar drift test** (append inside `archiveCatalogParserTests()`; reuse the file's existing `referenceDate`)

```swift
    await test("ArchiveCatalogParser ignores warnings and unknown line shapes (forward compat)") {
        let listing = """
        bsdtar: Warning: something changed in macOS 27
        -rw-r--r--  0 user group    1024 Jul  9 10:30 real.txt extra future column
        total 48
        -rw-r--r--+ 0 user group     512 Jul  9 10:30 acl-flagged.txt
        """
        let parsed = ArchiveCatalogParser.parse(listing: listing,
                                                referenceDate: referenceDate)
        expect(parsed.entries.contains { $0.name == "acl-flagged.txt" },
               "mode strings with ACL suffix still parse")
        expect(!parsed.entries.contains { $0.path.hasPrefix("bsdtar") },
               "warning lines don't become entries")
        expect(!parsed.entries.contains { $0.path == "total 48" },
               "summary lines don't become entries")
    }
```

- [ ] **Step 3: Run tests**

Run: `swift run FileExplorerTests 2>&1 | tail -4`
Expected: `PASS`. If either drift test fails, the parser is fragile against format drift — fix the parser (skip unparseable records; treat trailing extra fields as part of the path only when the format says so; tolerate `+`/`@` mode suffixes), not the test. Note: if `extra future column` ends up inside the parsed path, that is current whitespace-split behavior — acceptable (the entry is still usable and nothing crashes); assert only what forward-compat requires.

- [ ] **Step 4: Commit**

```bash
git add Sources/FileExplorerTests/GitStatusParserTests.swift Sources/FileExplorerTests/ArchiveCatalogParserTests.swift Sources/FileExplorerCore/
git commit -m "test: parser drift coverage for future git/bsdtar output"
```

---

### Task 12: Subprocess and runtime-assumption audit

Verification checklist — expected result is mostly "already correct"; fix anything that isn't.

**Files:**
- Possibly modify: `Sources/FileExplorerCore/GitStatusModel.swift`, `Sources/FileExplorerCore/Unarchiver.swift`

- [ ] **Step 1: Audit tool paths**

```bash
grep -rn 'executableURL' Sources/ | grep -v '/usr/bin/\|command.executable'
```

Expected: empty (all launches use absolute `/usr/bin/*` paths; `FileActionsMenu.swift:468` uses the user-configured tool, which is intended). Any other hit → change to an absolute path.

- [ ] **Step 2: Audit missing-tool behavior**

For each `Process()` site in `ArchiveBrowserModel`, `ArchiveExtractor`, `Unarchiver`, `Zipper`, `GitStatusModel`, `ScriptRunner`: confirm `try process.run()` failures are caught and surface as a user-visible error or a graceful no-op (git badges simply absent), never a crash. Read each site; list any unguarded `try!`/force paths and guard them.

- [ ] **Step 3: Verify known-trap coverage still holds**

```bash
grep -rn 'CommandsBuilder\|10-arg' docs/ Sources/FileExplorer/FileExplorerApp.swift | head
swift run FileExplorerTests 2>&1 | grep -iE 'trailing|private/tmp' | head
```

Confirm: top-level `Commands` entries in `FileExplorerApp.swift` remain grouped (≤10 builder args — count them), and the URL-normalization tests (trailing slash, `/private/tmp`) still exist and pass.

- [ ] **Step 4: Commit (only if something was fixed)**

```bash
git add -A Sources/
git commit -m "fix: harden subprocess failure paths for macOS 27"
```

---

### Task 13: README status note

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a compatibility section**

Add under the existing requirements/installation section:

```markdown
## macOS compatibility

Built for macOS 15+. Validated against the macOS 26 SDK (pinned `macos-26`
CI runners); parsers for `git`/`bsdtar` output are drift-tolerant and
benchmark smoke runs gate gross performance regressions. Re-validate on the
first macOS 27 beta: run `swift run FileExplorerTests` and
`swift run -c release FileExplorerBench --smoke` on the beta, then launch the
app and spot-check archive browsing and git badges.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: macOS compatibility and 27-beta validation notes"
```

---

### Task 14: Final verification and merge prep

- [ ] **Step 1: Full test suite**

Run: `swift run FileExplorerTests 2>&1 | tail -2` → `PASS (<n> assertions)`, n ≥ 1225.

- [ ] **Step 2: Full benchmark compare**

Run: `swift run -c release FileExplorerBench --compare .build/bench-baseline.json`
Expected: improvements hold, no scenario regressed >10%.

- [ ] **Step 3: Build and launch the real app**

```bash
./Scripts/bundle.sh && open build/FileExplorer.app
```

Manually: open a large folder (e.g. `~/Library/Caches/FileExplorerBench/full-v1/flat`), run Find Duplicates on the dupes fixture, browse a zip, confirm git badges in a repo. (Use the `verify` skill at execution time.)

- [ ] **Step 4: Wrap up**

Use the superpowers:finishing-a-development-branch skill to decide merge/PR for `v6.1-perf-macos27`.

---

## Self-review notes

- Spec coverage: bench target+fixtures (T2), scenarios+flags (T3), baseline (T4), DirectoryLoader (T5), prefilter+parallel+sort-at-yield (T6–7), CI smoke (T8), deprecations (T9), strict concurrency (T10), parser drift (T11), subprocess/runtime traps (T12), README (T13), verification (T14). ContentScanner/UsageScanner and PaneState consolidation are conditional in the spec ("only if baseline shows") — covered by T8 Step 1's regression check; no unconditional task on purpose.
- The 48 MB dupes tier honors the spec's "sizes up to ~50 MB".
- `sha256(of:firstBytes:)` naming is consistent across T6 and T7.
