# greedyfind

> **Educational and research use only.** See [`DISCLAIMER.md`](DISCLAIMER.md).

Metal-accelerated secp256k1 private-key discovery using multi-variant
range-splitting. Sibling to the CPU Rust crate
[`find`](https://github.com/sachncs/find).

Two modes:

- `--pubkey <hex>` — SEC1 hex public key.
- `--address <base58>` — P2PKH mainnet address (base58check).

Both modes sweep an arbitrary integer range `[from, to)` and search for
scalars `j` such that `x(j·G) == x(P - V·G)` (pubkey) or
`hash160(j·G) == hash160(P)` (address).

## Status

Pre-implementation. See [`plan.md`](plan.md) for the full 54-unit atomic
implementation plan. The build currently contains only the plan and supporting
files; no executable code is committed yet.

## Prerequisites

- macOS 14 or newer.
- Full **Xcode** installed (not just CommandLineTools — `xcrun metal` is
  required).
- CMake ≥ 3.25.

Verify with `bash scripts/check_toolchain.sh` after the toolchain-check unit
lands.

## License

MIT — see [`LICENSE-MIT`](LICENSE-MIT).

## Commit Author

`sachin <sachncs@gmail.com>` (repo-local config).