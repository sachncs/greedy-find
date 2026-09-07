# greedyfind

> **Educational and research use only.** See [`DISCLAIMER.md`](DISCLAIMER.md)
> and [`docs/security.md`](docs/security.md).

Metal-accelerated secp256k1 private-key discovery using multi-variant
range-splitting. Sibling to the CPU Rust crate
[`find`](https://github.com/sachncs/find).

Two modes:

- `--pubkey <hex>` — SEC1 hex public key.
- `--address <base58>` — P2PKH mainnet address (base58check).

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
    --pubkey 0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798 \
    --from 0 --to 1000000
```

This is a pubkey-mode sweep over the first million private keys
with the target being `d=1`. The output should contain a `MATCH
j=1+0` line.

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

Implementation complete through A53. Remaining work: A40–A44
throughput optimisations are kept iff the bench shows ≥5% gain
over the unoptimised baseline (see
[`docs/algorithms.md`](docs/algorithms.md) and
[`docs/architecture.md`](docs/architecture.md) for the
measured-revert rules).

## License

MIT — see [`LICENSE-MIT`](LICENSE-MIT).

## Commit author

`sachin <sachncs@gmail.com>` (repo-local config).
