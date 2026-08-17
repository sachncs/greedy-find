# architecture.md — host ↔ device pipeline and kernel grid

`greedyfind` is a host-driven Metal pipeline. The host owns
parsing, the variant table, the anchor table, multi-GPU
dispatch, and result recovery. The device owns the inner loop
(EC add, X compare, optional hash160).

```
                     host                               device
            ┌────────────────────┐                ┌────────────────┐
 argv ────▶ │  GRDOptionsFromArgv │                │                │
            │  (host/config.m)    │                │                │
            └──────────┬─────────┘                │                │
                       │                          │                │
            ┌──────────▼─────────┐                │                │
            │  GRDSweeper        │  setup         │                │
            │  Factory           │ ────────────▶  │  newDevice     │
            │  (host/sweep.m)    │                │  newQueue      │
            │                    │                │  newLibrary    │
            │  per mode:         │                │  newPipeline   │
            │   GRDPubkeySweeper │  variants      │                │
            │   GRDAddressSweeper│ ────────────▶  │  variants buf  │
            │                    │  anchor table  │                │
            │                    │ ────────────▶  │  anchor buf    │
            │                    │  prune bitmap  │                │
            │                    │ ────────────▶  │  bitmap buf    │
            │                    │                │                │
            │                    │  cmd buffer    │                │
            │                    │ ────────────▶  │  grdPrune      │
            │                    │  cmd buffer    │                │
            │                    │ ────────────▶  │  grdSweep*     │
            │                    │                │   ├ batch inv  │
            │                    │                │   ├ EC add     │
            │                    │                │   ├ X cmp      │
            │                    │                │   └ match      │
            │                    │ ◀────────────  │  match buffer  │
            │                    │                │                │
            │  GRDCheckpointStore│                │                │
            │  GRDTelemetry      │                │                │
            │  GRDCache          │                │                │
            └────────────────────┘                └────────────────┘
```

## 1. Host pipeline (`host/sweep.m`)

`GRDRunSession` is the entry point invoked by `host/main.m`. It
parses argv into a `GRDOptions` struct and dispatches to one of
two sweepers based on `opts.mode`:

- `GRDPubkeySweeper` (--pubkey)
- `GRDAddressSweeper` (--address)

For tiny ranges (< 2^20 j), the dispatcher falls back to a
CPU sweep using libsecp256k1. The GPU path is reserved for
ranges large enough to amortise the dispatch overhead.

## 2. Sweeper setup (`host/sweeper.m`)

Each sweeper inherits from `GRDSweeperBase`, which handles:

- Device creation (`MTLCreateSystemDefaultDevice()`).
- Command queue creation.
- Metal library load (`greedy.metallib`).
- Cancellation flag.

The pubkey sweeper then:

1. Creates two compute pipelines (`grdVariantPrune` and
   `grdSweepPubkey`).
2. Uploads the variant table (`512 × GRDVariant`).
3. Uploads the target X (32 bytes big-endian).
4. Allocates a 64-byte productivity bitmap.
5. Allocates a match buffer (256 × UInt256x64) and a
   4-byte atomic match counter.

The address sweeper is currently a stub; the address-mode GPU
path lands in A40+.

## 3. Kernel grid

### `grdVariantPrune` (metal/sweep.metal)

One thread per variant. Walks the variant table, computes
`x(P - V·G) mod n`, and sets the productivity bit accordingly.
Run once at sweep start, then the bitmap is read-only for the
duration of the sweep.

### `grdSweepPubkey` (metal/sweep_pubkey.metal)

Threadgroup size 32 lanes. Dispatch is `B` threadgroups per
anchor (`B` = batch size, default 32). Each threadgroup
processes one anchor:

- All 32 lanes share the anchor (loaded into threadgroup
  memory).
- Lane `i` tests variant `i` (with sign alternation for
  negative `V`).
- The kernel does one field add (`j = anchor + V mod n`),
  one EC add, and one X compare per lane.

### Variants

A40–A43 add kernel variants:

- `grdBatchInvertSimd` (A40) — simdgroup-flavoured batch
  inversion.
- `grdSweepPubkeyLocal` (A42) — threadgroup-local match
  buffer.
- `grdBuildPrefixIndex` + `grdSweepPubkeyPrefix` (A43) —
  8-byte prefix index for first-pass filtering.

Each is a measured-revert candidate: kept iff the bench shows
≥5% gain over the unoptimised baseline.

## 4. Multi-GPU dispatch (`host/sweep_pipelined.{h,m}`)

The A41 pipelined dispatcher splits `[from, to)` into `N`
slices (N=1..8) and issues one command buffer per slice. A
serial dispatch queue merges the match outputs. The
`GRDLoadBalancer` (A44) tracks per-device throughput and
rebalances: the slowest device loses 10% of its slice to the
fastest, capped so the slow slice stays positive. A rebalance
is a no-op when the fastest/slowest ratio is within 5%.

## 5. Result recovery and persistence

Matches are written into a global match buffer (atomic counter
per match in the unoptimised path; per-threadgroup flush in the
A42 path). The host reads the buffer on command-buffer
completion and converts each match into a `GRDMatch` (j,
variant label).

A47-style telemetry emits one NDJSON line per event to
`events.ndjson` and a human-readable line to `events.log`.
The host also calls `GRDCheckpointStore` periodically to
persist the next-j position to a small JSON file; on
`--resume`, the loader reads the file, verifies its
SHA-256 integrity hash, and resumes from the saved position.

## 6. Caching (`host/cache.{h,m}`)

The A33 cache mirrors the `find` crate's row-major
variant×anchor layout and the `FIND-CAC` file magic. Writes
are serialised through a single dispatch queue and finalised
with write-then-rename, so a parallel sweep can safely call
`setX:forVariant:anchor:` from any thread.
