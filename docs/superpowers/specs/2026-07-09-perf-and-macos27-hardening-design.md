# Performance Pass + macOS 27 Hardening — Design

**Date:** 2026-07-09
**Status:** Approved
**Scope:** v6.1 maintenance line. No new features, no UI changes, deployment target stays `macOS 15`.

## Goals

1. Measurably speed up FileExplorerCore hot paths, with a benchmark harness that
   proves each win and guards against regressions in CI.
2. Ensure the app builds and runs cleanly on macOS 27 (releasing fall 2026)
   without bumping the deployment target.

Two milestones, shipped independently: M1 (benchmarks + perf), M2 (compat).

## Milestone 1 — Benchmark harness + core performance

### FileExplorerBench target

New executable target `FileExplorerBench` (depends on `FileExplorerCore`),
mirroring the `FileExplorerTests` harness pattern — the CLT-only toolchain has
no XCTest or `swift test`, so benchmarks are a plain executable.

**Fixtures** — generated under a temp directory on first run, reused across
runs (regenerated if missing or version-stamped stale):

| Fixture | Shape | Exercises |
|---|---|---|
| `flat50k` | 50,000 files, one directory | DirectoryLoader, FileSorter, FilterEngine |
| `deep250k` | ~250,000 entries, depth ~12 | UsageScanner, ContentScanner enumeration |
| `dupes` | ~2,000 files, ~30% duplicate ratio, sizes 1 KB–50 MB | DuplicateFinder end-to-end |
| `bigzip` | zip with several thousand entries | ArchiveCatalogParser |

**Scenarios** — each timed as median of N runs (default N=5) after one warm-up:
`directory-load`, `sort-filter`, `duplicate-scan`, `usage-scan`,
`content-scan`, `archive-parse`.

**Output** — human table plus one machine-readable line per scenario
(`bench:<scenario> median_ms=<n> runs=<n>`). Flags: `--json <path>` to save a
run, `--compare <path>` to diff against a saved baseline and report deltas.

**CI** — a smoke variant (`--smoke`: small fixtures, generous absolute
thresholds) runs in the existing workflow. It exists to catch gross
regressions (10× blowups), not small drift — timing gates on shared runners
flake otherwise.

### Optimization candidates (confirm with baseline before fixing)

- **DirectoryLoader double-stat:** `load()` calls `resourceValues` twice per
  entry — the main key set, then a second call for `.contentTypeKey`. Fold
  `.contentTypeKey` into the single key set. Halves per-entry metadata round
  trips; biggest effect on network volumes.
- **DuplicateFinder hashing:** candidates within a size bucket are hashed
  fully and sequentially. Add a partial-hash prefilter (first 64 KB) so
  same-size-but-different files drop out cheaply; parallelize surviving full
  hashes across a bounded task group (width ~ProcessInfo.activeProcessorCount,
  capped). Preserve existing ordering and cancellation semantics.
- **DuplicateFinder re-sort:** the per-size loop re-sorts the entire
  accumulated `groups` array on every yield. Sort once per yield of the
  snapshot instead of maintaining a globally sorted array during accumulation.
- **ContentScanner / UsageScanner:** verify enumerator key sets are minimal
  and per-entry allocations don't dominate. Touch only if the baseline shows a
  scenario worth improving.
- **PaneState `Task.detached` hops (~10 sites):** consolidate only if
  inspection shows redundant loads (e.g., double load on navigation);
  otherwise leave alone.

Rule: anything the baseline shows is already fast stays untouched. Each fix
lands with before/after benchmark numbers in the commit message.

## Milestone 2 — macOS 27 compatibility hardening

- **Deprecation & availability audit.** Triage build with warnings surfaced;
  sweep for APIs deprecated as of the macOS 26 SDK. Fix or `#available`-gate.
  `platforms: [.macOS(.v15)]` stays.
- **Strict concurrency.** Triage pass with `-strict-concurrency=complete`
  (not committed as a flag). Fix real `Sendable`/race gaps in
  FileExplorerCore; UI-target fixes only where cheap given the documented
  CLT `@State`-macro constraints.
- **Subprocess contracts.** The app shells out to `bsdtar`, `git`, `hdiutil`,
  and friends. Every parser must tolerate format drift: unknown lines
  ignored, version probed where output differs across releases, absolute
  system tool paths (never PATH-dependent). Add parser tests that feed
  intentionally mutated output.
- **Runtime assumptions.** Verify trailing-slash and `/private/tmp` URL
  normalization coverage (existing traps with tests), TCC-sensitive calls
  degrade gracefully, and top-level `Commands` entries stay within the
  10-arg builder cap (known CI trap on older SDKs).
- **CI.** Pin the GitHub Actions runner image (no floating `macos-latest` —
  known feature-skew trap). Note macOS 27 validation status in the README.

## Testing & verification

- Existing harness (1208 assertions) green after every change.
- New: parser-drift tests, benchmark smoke in CI.
- Perf claims verified only via `FileExplorerBench` before/after numbers on
  the development machine.
- Final pass: launch the real app against a large folder to confirm no
  behavioral regressions.

## Out of scope

- Deployment-target bump; adopting new macOS 26/27 APIs.
- UI redesign or thumbnail-pipeline rework (AppKit/QuickLook layer — not
  measurable without Instruments). Revisit only if UI-level lag is observed.

## Error handling

Benchmark fixture generation failures abort the run with a clear message and
clean up partial fixtures. `--compare` against a missing/incompatible baseline
exits nonzero with a diagnostic rather than reporting bogus deltas.
Optimizations must preserve existing error semantics (e.g., DuplicateFinder's
skip-on-unreadable, DirectoryLoader's drop-on-TOCTOU).
