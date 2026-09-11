# Changelog

All notable changes to `greedyfind` are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic
Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- macOS Metal CI workflow (`.github/workflows/ci.yml`) that builds
  on `macos-14` and runs the KAT suite.
- `LICENSE` file at the repo root (renamed from `LICENSE-MIT`) so
  GitHub and downstream tooling detect the licence by canonical
  filename.
- `GRDPrimePMinus2` constant in `host/ecc.c`; the Fermat inverse
  exponent is now derived from it instead of four hand-written
  locals.
- `cmake --install` rule for `greedyfind`, the `LICENSE`, and the
  `docs/` tree.
- `find_library` / `find_path` discovery for `libsecp256k1` (and
  `libtomcrypt`), with an opt-in `SECP256K1_PREFIX` env-var
  override for the original Apple-Silicon Homebrew layout.
- `GRD_VERSION` compile-definition propagated from
  `project(VERSION ...)` so `--version` has a single source of truth.
- `bench/README.md` documents how to record a baseline and what
  every JSON field means.
- `README.md` "What this tool cannot do" callout, an ASCII
  architecture diagram, and a Troubleshooting section.

### Changed
- Per-device `anchorsBuffer` (96 MiB) removed; the v0.1 kernel
  reads from the per-slice staging buffer instead. Smoke tests no
  longer pin VRAM.
- `GRDMatchBufferSlots` constant reconciles the host's 256-slot
  cap with the kernel's slot-bounds check.
- `examples/run.sh` now fails loudly if `--address` silently
  accepts an input instead of returning its A40+ stub error.
- README Status block rewritten in user-facing language (no
  internal A-prefixed unit IDs).
- README Quick start reordered so the build is step 1 and the
  toolchain check is optional.

### Fixed
- `--from -1` / `--from +1` now rejected at parse time
  (`GRDU128ParseDecimal` refuses signed inputs).
- `--from/--to` values whose hi limb is non-zero rejected with
  a clear "u128 ranges > 2^64 not supported" error.
- P2SH addresses (version byte `0x05`) rejected at parse time
  with a clear "P2SH not supported in v0.1" error.
- `--cache-points` rejected with a clear "not yet implemented"
  error (the flag was previously parsed but never wired through).
- `secp256k1_ec_pubkey_parse` return checked for the hardcoded
  `G` constant; a typo or library upgrade that breaks the parse
  now surfaces as a fatal setup error.
- libsecp256k1's illegal-callback messages are now written to
  stderr instead of being silently dropped.
- `record_baseline.sh` now pipes the JSON line via stdin instead
  of triple-quoted shell interpolation, so embedded triple-quotes
  no longer break the script.
- The per-slice completion dispatch was racing with the merge
  queue; both the `all_matches` append and the final completion
  now run on `merge_q`, so the completion observes a fully-merged
  match array.
- Dead `tests/unit/` GLOB block removed from `CMakeLists.txt`
  (the directory never existed; the GLOB silently no-op'd).

### Removed
- Four `fprintf(stderr, "grd-debug: ...")` statements from
  `host/sweeper.m`'s dispatch path.
- The `else if` DEBUG branch in `metal/sweep_pubkey.metal` that
  bumped `match_count` to 1 for every sweep.

### Known limitations
- `--address` mode is a stub; only `--pubkey` works end-to-end.
- u128 ranges > 2^64 are rejected.
- P2SH addresses are rejected.
- The Metal sweep kernel decodes only the low 64 bits of `j`.

## [0.1.0] - 2026-08-16

### Added
- Metal-accelerated `--pubkey` mode (secp256k1 range-splitting on
  Apple Silicon).
- Host-side field/point arithmetic reference in `host/ecc.c`.
- KAT suite (`tests/kat/`) covering field ops, hash160,
  base58check decode.
- Smoke script (`examples/run.sh`) and reliability matrix
  (`scripts/reliability.sh`).
- Bench harness (`bench/sweep_bench.m`) and bench-regression gate
  (`scripts/run_bench.sh`).