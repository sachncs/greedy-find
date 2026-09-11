# greedyfind

> **Educational and research use only.** See [`DISCLAIMER.md`](DISCLAIMER.md)
> and [`docs/security.md`](docs/security.md).

Metal-accelerated secp256k1 private-key discovery using multi-variant
range-splitting. Sibling to the CPU Rust crate
[`find`](https://github.com/sachncs/find).

Two modes:

- `--pubkey <hex>` — SEC1 hex public key. **Implemented.**
- `--address <base58>` — P2PKH mainnet address (base58check).
  **Not yet implemented in v0.1; the flag is parsed but the
  GPU sweep path returns an `--address on GPU lands in A40+`
  error.**

Both modes sweep an arbitrary integer range `[from, to)` and search for
scalars `j` such that `x(j·G) == x(P - V·G)` (pubkey) or
`hash160(j·G) == hash160(P)` (address).

## Quick start

### 1. Check the toolchain

```bash
bash scripts/check_toolchain.sh
```

Verifies macOS 14+, full Xcode (not just CommandLineTools), cmake
≥ 3.25, and the local git author.

### 2. Build

```bash
cmake -S . -B build
cmake --build build -j
```

The first cmake invocation configures; the second compiles the host
binary, the Metal kernels (linked into `greedy.metallib`), the
unit and KAT tests, and the bench harness. `metallib` is embedded
next to the executable via `BUILD_RPATH`.

### 3. Smoke test (both modes)

```bash
bash examples/run.sh
```

Runs a tiny sweep (`[0, 16)`) with privkey=1 in both `--pubkey` and
`--address` modes and asserts that the d=1 match is found.

### 4. Run the KATs

```bash
bash scripts/run_kat.sh
```

Builds and runs every KAT in `tests/kat/`, printing PASS/FAIL per
KAT. Exits non-zero on the first failure.

### 5. Try it on a real range

```bash
./build/greedyfind \
    --pubkey 02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5 \
    --from 0 --to 1000000
```

This is a pubkey-mode sweep over the first million private keys
with the target being `d=2`. The smallest recoverable scalar in
--pubkey mode is `d=2` (the variant table contains no `V=0`;
`d=2` corresponds to `j=0, V=2, candidate = 0 + 2·G = 2·G`). The
output should contain a `MATCH j=0+2` line.

## More

- [docs/algorithms.md](docs/algorithms.md) — the math behind
  range-splitting, the variant table, and the per-threadgroup
  batch inversion.
- [docs/architecture.md](docs/architecture.md) — host ↔ device
  pipeline and the kernel grid.
- [docs/cli.md](docs/cli.md) — every flag with examples.
- [docs/configuration.md](docs/configuration.md) — environment
  variables, output directory layout, checkpoint format.
- [docs/security.md](docs/security.md) — threat model and
  research-only disclaimer.
- [plan.md](plan.md) — the 54-unit atomic implementation plan and
  per-unit quality gates.

## Status

What's implemented:

- `--pubkey` mode (secp256k1 X-coordinate sweep) over an
  arbitrary `[from, to)` range, on Apple Silicon via Metal.
- Host-side reference field/point arithmetic
  (`host/ecc.c`) used by the KAT suite.
- KATs for field ops, hash160, base58check decode, address
  parsing, variant generation, load balance, telemetry,
  checkpointing.
- Reliability matrix (`scripts/reliability.sh`) and a
  differential test against the `find` Rust crate
  (`scripts/differential.sh`).
- Cache layer (`GRDCache`) plumbing; integration with the
  sweep pipeline is on the roadmap.

What's on the roadmap:

- Address-mode GPU sweep — currently a stub that returns
  "not yet implemented".
- u128 ranges > 2^64 — the v0.1 kernel decodes only the low
  64 bits and silently truncates anything larger. The CLI
  rejects these with a clear error.
- P2SH (version 0x05) address decoding — the CLI rejects it.
- Throughput optimisations from the A40–A44 batch are gated
  on a ≥5% bench win over the unoptimised baseline.

## License

MIT — see [`LICENSE`](LICENSE).

## Commit author

`sachin <sachncs@gmail.com>` (repo-local config).
