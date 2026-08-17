# configuration.md — config-file and environment-variable reference

`greedyfind` is configured primarily through CLI flags (see
`docs/cli.md`). A small set of environment variables override
defaults for the verification scripts.

## Environment variables

### `FIND_BIN`

Override the binary used by `scripts/differential.sh` for the
output-comparison test against the `find` Rust crate. Default
`find` (looked up on `PATH`).

```bash
FIND_BIN=/path/to/find bash scripts/differential.sh
```

### `GRD_BASELINE_JSON`

Override the JSON file used by `scripts/run_bench.sh` and
`scripts/record_baseline.sh` as the throughput regression
baseline. Default `benchmarks/baseline_m3pro.json`.

```bash
GRD_BASELINE_JSON=benchmarks/baseline_m4max.json \
    bash scripts/run_bench.sh
```

### `REGRESSION_PCT`

Override the percent drop that `scripts/run_bench.sh` treats
as a regression. Default 5.

```bash
REGRESSION_PCT=10 bash scripts/run_bench.sh
```

## CMake options

### `GRD_BUILD_TESTS`

`ON` by default. When enabled, every `tests/kat/*` file is
compiled into a standalone KAT executable and registered with
CTest. Disable for a release build:

```bash
cmake -S . -B build -DGRD_BUILD_TESTS=OFF
```

### `GRD_BUILD_BENCH`

`ON` by default. When enabled, `bench/*.m` are compiled into
standalone microbench harnesses. Disable for a release build
that doesn't need the bench.

## Output directory layout

By default, `--output-dir` and `--log-dir` both point at
`./greedyfind-out`. The directory contains:

```
greedyfind-out/
├── <descriptor>.bin       # per-target cache (FIND-CAC magic)
├── <descriptor>.ckpt      # atomic checkpoint, SHA-256 integrity
├── events.ndjson          # one JSON event per line
├── events.log             # rolling human-readable log
└── events.ndjson.1        # rotated NDJSON (after 64 MiB)
```

`<descriptor>` is a 16-char hex digest of
`(target_x || from || to)` so different (target, range) pairs
don't collide.

## Checkpoint file format

```
{
  "next_j_lo": "0123456789abcdef",
  "next_j_hi": "fedcba9876543210",
  "integrity": "sha256-of-the-rest"
}
```

The integrity hash is SHA-256 of the bytes
`"next_j_lo":"...","next_j_hi":"..."` (the field list, no
surrounding braces). On load, the host re-derives the hash and
rejects the file if it doesn't match. A failed integrity check
is a real error (exit code 70), not a silent fallback to a
fresh start.

## NDJSON event schema

Each line is a single JSON object with at least:

```json
{
  "ts": "2026-08-17T15:00:00.000Z",
  "name": "sweep.progress",
  "level": 1,
  "from_lo": "0",
  "to_lo": "1000000",
  "j_per_sec": 12345678
}
```

`name` is dotted (`sweep.start`, `sweep.progress`,
`sweep.match`, `sweep.end`, `checkpoint.saved`, `cache.flushed`).
`level` is `0=DEBUG, 1=INFO, 2=WARN, 3=ERROR`. The text log
filters by `textLevel` (default INFO); the NDJSON file
records every event.
