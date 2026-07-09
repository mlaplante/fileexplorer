# Benchmark Baseline (pre-optimization)

Recorded 2026-07-09 at commit 793c99b on Apple M4, macOS 27.0.
Full profile (`swift run -c release FileExplorerBench --json .build/bench-baseline.json`), median of 5 runs after 1 warm-up.

```
bench:directory-load median_ms=2117.6 runs=5
bench:sort-filter median_ms=2528.2 runs=5
bench:duplicate-scan median_ms=556.4 runs=5
bench:usage-scan median_ms=10997.5 runs=5
bench:content-scan median_ms=414.5 runs=5
bench:archive-parse median_ms=50.9 runs=5
```

Baseline JSON lives locally at `.build/bench-baseline.json` (machine-specific, not committed).

## After Milestone 1 perf fixes (2026-07-09)

Same machine, same fixtures, `--compare` against the baseline above:

```
archive-parse: 50.9 ms → 50.1 ms (-1.5%)
content-scan: 414.5 ms → 401.0 ms (-3.3%)
directory-load: 2117.6 ms → 1114.7 ms (-47.4%)
duplicate-scan: 556.4 ms → 139.0 ms (-75.0%)
sort-filter: 2528.2 ms → 1353.1 ms (-46.5%)
usage-scan: 10997.5 ms → 6060.2 ms (-44.9%)
```
