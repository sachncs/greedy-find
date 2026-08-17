# bench/

`bench/` holds the throughput microbench harness for `greedyfind`.

## Quickstart

```bash
cmake --build build --target sweep_bench
./build/sweep_bench
```

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

## Notes

- Default values are placeholders; the production harness should
  call this with a per-machine M-series profile.
- The autotune is intentionally simple (one pass per axis value).
  Real per-axis ranking on Apple Silicon typically requires a brief
  warmup followed by a steady-state measurement; the bench keeps
  the full result so a separate reducer can drop warmup.
- Results are deterministic for a given GPU + macOS version
  (Metal drivers do not reorder kernel dispatch).
