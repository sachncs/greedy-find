# bench/

`bench/` holds the throughput microbench harness for `greedyfind`.

## Quickstart

```bash
cmake --build build --target sweep_bench
./build/sweep_bench
```

## Recording a baseline

The bench's JSON one-liner is the input to `scripts/run_bench.sh`'s
regression gate. To re-capture the baseline on a known-good M-series
host:

```bash
GRD_BASELINE_JSON=benchmarks/baseline_m3pro.json \
  bash scripts/record_baseline.sh
```

The script reads the bench's most recent JSON line, merges it into
the existing baseline file, and updates `date`. Override
`GRD_BASELINE_JSON` to write to a different file. The `mode` field
in the baseline switches to `metal` automatically when the bench's
GPU pipeline is reachable; a `cpu` mode baseline is a fallback for
hosts without a working Metal runtime and should not be used as the
regression gate for GPU work.

## What it measures

`sweep_bench.m` runs the `grdSweepPubkey` Metal kernel with a fixed
target (privkey=1, G) over a 2^14-j range. For each axis it varies
one knob while holding the others at the production default, prints
a small table, and tracks the best per axis.

- **A37 — threadgroup size**: 16, 32, 64, 128 lanes per threadgroup.
- **A38 — anchor interval**: 2^12, 2^14, 2^16, 2^18, 2^20.
- **A39 — variant count**: 256 vs 512.

The final line is a one-line JSON summary suitable for downstream
regression gates (`scripts/run_bench.sh`, A47).

## Baseline fields

- `machine` — host description; humans only.
- `metal_toolchain` — Metal compiler version (e.g. `metal3.0`).
- `date` — capture date (YYYY-MM-DD).
- `mode` — `metal` for a GPU-derived baseline, `cpu` for the libsecp256k1 fallback.
- `bench` — the bench binary that produced the line (`sweep_bench`).
- `tg` — threadgroup size used in the capture.
- `anchor_k` — anchor-interval knob used in the capture.
- `variants` — variant count used in the capture.
- `range` — j-range width (anchors tested).
- `j_per_sec` — anchors/sec; the regression gate key.
- `ec_adds_per_sec` — derived throughput stat.
- `wall_s` — total wall-clock seconds for the bench.
- `note` — optional human note (e.g. capture-host caveat).

## Notes

- Default values are placeholders; the production harness should
  call this with a per-machine M-series profile.
- The autotune is intentionally simple (one pass per axis value).
  Real per-axis ranking on Apple Silicon typically requires a brief
  warmup followed by a steady-state measurement; the bench keeps
  the full result so a separate reducer can drop warmup.
- Results are deterministic for a given GPU + macOS version
  (Metal drivers do not reorder kernel dispatch).
