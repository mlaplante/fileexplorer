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
        // Cache key embeds the profile's counts so editing BenchProfile
        // invalidates stale fixtures instead of silently reusing them.
        let root = cachesDir.appendingPathComponent(
            "FileExplorerBench/\(profile.name)-v1-\(profile.flatFileCount)-\(profile.deepEntryCount)-\(profile.dupeFileCount)",
            isDirectory: true)
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

    /// Deep: budget-limited BFS, 6 dirs wide with 8 files each — lands
    /// shallow-and-wide (depth ~4-6), which matches how enumeration cost
    /// scales (entry count, not depth). One file in ~50 contains the
    /// content-scan needle.
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
            (4 * 1024, 0.60), (256 * 1024, 0.36),
            (8 * 1024 * 1024, 0.03), (48 * 1024 * 1024, 0.003),
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
                    var tail = original                   // identical except the
                    tail[tail.count - 1] ^= 0xFF          // final byte
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
