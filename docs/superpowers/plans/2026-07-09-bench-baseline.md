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
