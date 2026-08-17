# greedyfind — Implementation Plan

> **Metal-accelerated secp256k1 private-key discovery using multi-variant range-splitting.**
> Repository: `git@github.com:sachncs/greedy-find.git` · Commit author: `sachin <sachncs@gmail.com>`
> Educational and research use only. See `DISCLAIMER.md`.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Goals and Non-Goals](#2-goals-and-non-goals)
3. [Toolchain Prerequisites](#3-toolchain-prerequisites)
4. [Coding Standards](#4-coding-standards)
5. [Architecture](#5-architecture)
   - 5.1 [Polymorphic Protocol Layer](#51-polymorphic-protocol-layer)
   - 5.2 [Zero-Communication-Overhead Design Rules](#52-zero-communication-overhead-design-rules)
6. [File Layout](#6-file-layout)
7. [Atomic Implementation Plan (54 Units)](#7-atomic-implementation-plan-54-units)
8. [Per-Unit Quality Gates](#8-per-unit-quality-gates)
9. [Verification Matrix](#9-verification-matrix)
10. [Throughput Expectations](#10-throughput-expectations)
11. [Risks](#11-risks)
12. [Locked Decisions](#12-locked-decisions)

---

## 1. Overview

`greedyfind` is the Metal-accelerated sibling of the existing CPU Rust crate
[`find`](https://github.com/sachncs/find). It implements the same multi-variant
range-splitting algorithm and adds two modes:

| Mode | Trigger | Per-`j` cost | Use case |
|---|---|---|---|
| `--pubkey` | SEC1 hex public key | 1 EC add + 1 variant-index lookup | Bitcoin Puzzle #N where the compressed pubkey is known |
| `--address` | Base58check P2PKH address | 1 EC add + affine projection + SHA-256 + RIPEMD-160 + hash160 compare | Bitcoin Puzzle #N where only the address is known |

For an arbitrary integer range `[from, to)` and target `P` (or its hash160), the
algorithm searches for scalars `j` and offsets `V` such that either

- `x(j·G) = x(P - V·G)` (pubkey mode), or
- `hash160(j·G) == hash160(P)` (address mode),

yielding candidate private keys `d = V ± j (mod n)` (pubkey mode) or `d = j`
(address mode). Both modes reuse the same range-splitting infrastructure
(anchor tables every `2^16` threadgroups, multi-GPU partition, Montgomery
batch inversion per threadgroup).

The reference range for v0.1 is **`[2^70, 2^71)`** — a Bitcoin Puzzle #71-style
search space. Throughput is measured on the target host via `bench/sweep_bench`; the
repo does not project a number.
hardware; see §10.

---

## 2. Goals and Non-Goals

### Goals

- Replicate `find`'s public surface in Objective-C + Metal: `--pubkey`,
  `--address`, `--from`, `--to`, `--cache-points`, `--batch-size`,
  `--variants`, `--anchor-interval`, `--gpu`.
- Atomic, reviewable unit plan: every commit compiles clean, passes KATs, and
  leaves the build green.
- Apple Silicon only (M1–M4). Unified memory, modern MSL (`metal3.0`).
- Polymorphic protocol-based design (§5.1) so adding a third mode is local.
- Byte-compatible binary cache with `find` (`docs/adr/0006-binary-cache-format.md`).
- Multi-GPU dispatch via `MTLCopyAllDevices()` + `dispatch_group_t`.
- Throughput-maximising optimisations with measured-revert rules.

### Non-Goals

- Constant-time / signing-key recovery. Threat model mirrors `find`.
- iOS, Intel Mac, or any non-Apple-Silicon target.
- Multi-node distribution.
- Replacement for `find`; differential test vectors flow one-way out of `find`.
- CUDA / OpenCL / Vulkan backends.
- Full `k256` ABI; we reimplement only the operations needed for the sweep.

---

## 3. Toolchain Prerequisites

| Requirement | How to verify | Failure mode |
|---|---|---|
| macOS 14 or newer (for `metal3.0`) | `sw_vers` | CMake configure fails fast |
| Full Xcode (provides `xcrun metal` and `xcrun metallib`) | `xcrun --find metal` | `scripts/check_toolchain.sh` exits non-zero |
| CommandLineTools alone is **insufficient** | this host has only CLT today | install full Xcode before building |
| CMake ≥ 3.25 | `cmake --version` | install via `brew install cmake` |
| Git author set locally | `git config --local user.name` shows `sachin` | first commit fails otherwise |

The repo-local git config (set during unit A1) is:

```ini
[user]
    name = sachin
    email = sachncs@gmail.com
```

---

## 4. Coding Standards

### 4.1 Google Objective-C Style Guide

Compiled from <https://google.github.io/styleguide/objcguide.html>. The host
code must conform to:

- **Indentation**: 2 spaces, no tabs.
- **Line length**: 80 columns.
- **Naming**:
  - `UpperCamelCase` for classes, protocols, and categories.
  - `lowerCamelCase` for methods, properties, and local variables.
  - `_lowerCamelCase` for instance variables (underscore prefix).
  - `g` prefix for file-scope globals; `k` prefix for static constants in `.m`.
  - `SHOUTY_SNAKE_CASE` for macros; `kFooBar` is **no longer recommended** for
    public constants — use `GRDFooBar` (class + constant).
- **Prefix**: every class, protocol, global function, and global constant uses
  the **`GRD`** prefix (3+ chars; Apple reserves 2-letter prefixes).
- **Designated initializers**: marked `NS_DESIGNATED_INITIALIZER`; superclass
  designated initializers overridden.
- **No `+new`**: always `[[self alloc] initWith...]`.
- **No `@throw`**: error delivery via `NSError **` out-parameters only.
- **No `@synchronized`**: use `dispatch_queue` or `os_unfair_lock`.
- **Nullability**: every header wrapped in
  `NS_ASSUME_NONNULL_BEGIN` / `NS_ASSUME_NONNULL_END`; explicit
  `nullable` / `nonnull` keywords (no underscore forms).
- **Lightweight generics**: `NSArray<GRDMatch *> *`, never bare `NSArray *`.
- **Forward declarations**: `@class GRDFoo;` in headers; `#import` only the
  related header first in `.m`.
- **Properties**: `nonatomic` (we are a CLI; no need for `atomic`),
  `strong` / `weak` / `copy` as appropriate; `readonly` unless mutated.
- **Comments**: Doxygen `/** ... */` for every public API; `//` for
  implementation; at least 2 spaces before end-of-line comments.
- **Avoid `id`**: use `id<GRDProtocol>` for protocol-typed values; specific
  class types elsewhere.
- **Avoid messaging `self` in `init` / `dealloc`**: assign ivars directly.
- **No `goto`**.
- **Header ivars**: declared in `.m`, not `.h`. (When in a header, mark
  `@protected` or `@private`.)
- **Includes order**: related header → OS → language library → other deps,
  each group alphabetised, blank line between groups.

### 4.2 `.clang-format`

Checked in at the repo root during unit A2:

```yaml
# .clang-format (Google base, with project overrides)
BasedOnStyle: Google
Language: ObjC
ColumnLimit: 80
IndentWidth: 2
TabWidth: 2
UseTab: Never
DerivePointerAlignment: false
PointerAlignment: Left
ReflowComments: true
SortIncludes: true
IncludeBlocks: Preserve
```

Run `clang-format -i <file>` on every modified `.h`, `.m`, `.c` before commit.
Metal sources are formatted by hand using the same conventions; `clang-format`
does not currently support Metal.

### 4.3 MSL Style

For `.metal` files:

- 2-space indentation.
- 80-column lines.
- `lowerCamelCase` for functions; `UpperCamelCase` for structs; `kFooBar` for
  constants in the `k` prefix style (this is metal, not Apple ObjC; `k` prefix
  is the metal convention).
- Functions: `void FieldAdd(device const uint32_t *a, ...)` style — verb-first.
- `kernel` qualifiers: `[[kernel]]`, attributes on separate lines.
- All `device`, `threadgroup`, `constant` qualifiers explicit; no implicit
  address-space inference.

---

## 5. Architecture

### 5.1 Polymorphic Protocol Layer

Inheritance-based polymorphism is brittle here — modes diverge in state, kernel
encoding, and match semantics, and accidental superclass overrides create
hard-to-trace bugs. Protocols give sealed roles with one concrete factory
doing the mode dispatch.

Five protocol extension points:

#### 5.1.1 Target representation (`GRDTarget`)

```objc
NS_ASSUME_NONNULL_BEGIN

/**
 * Protocol abstracting a search target. Implementations know how to verify
 * a candidate private key recovers the public key (or hash thereof) that
 * the user supplied on the command line.
 *
 * Implementations are pure value objects; no Metal dependencies.
 */
@protocol GRDTarget <NSObject>

/**
 * Returns the canonical hash bytes used to verify a candidate against this
 * target. For pubkey targets: the X-coordinate of the supplied compressed
 * pubkey (32 bytes). For address targets: the 20-byte hash160 of the
 * supplied P2PKH address.
 */
- (nonnull NSData *)verificationHash;

/**
 * Verifies that @c candidate recovers the target's verificationHash.
 *
 * @param candidate The candidate private key to verify.
 * @param error     Out-parameter for recoverable errors. Pass NULL to ignore.
 * @return YES if the candidate verifies; NO otherwise (with @c error set).
 */
- (BOOL)verifyCandidate:(nonnull GRDCandidate *)candidate
                  error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
```

Concrete implementations:

- `GRDPubkeyTarget` — SEC1-hex input; verifies via `(d·G).x == target.x`.
- `GRDAddressTarget` — base58check input; verifies via
  `hash160(compressed(d·G)) == target.hash160`.

#### 5.1.2 Sweep algorithm (`GRDSweeper`)

```objc
NS_ASSUME_NONNULL_BEGIN

/**
 * Protocol for a Metal device worker that searches a sub-range of [from, to)
 * for the target. One concrete instance per Metal device.
 *
 * Thread safety: dispatchSweepWithCompletion: may be called from any host
 * thread; the completion block fires on an internal serial queue.
 */
@protocol GRDSweeper <NSObject>

/**
 * Designated initializer.
 *
 * @param config The session configuration. Retained.
 * @param device The Metal device this sweeper operates on. Retained.
 * @param error  Out-parameter for recoverable errors.
 */
- (nullable instancetype)initWithConfig:(nonnull GRDConfig *)config
                                  device:(nonnull id<MTLDevice>)device
                                   error:(NSError * _Nullable * _Nullable)error
    NS_DESIGNATED_INITIALIZER;

/**
 * One-time setup for the [from, to) range. Uploads buffers, builds pipeline
 * states, and encodes the variant-prune / anchor-init kernels. Must be
 * called before dispatchSweepWithCompletion:.
 */
- (BOOL)prepareForRange:(nonnull GRDRange *)range
                  error:(NSError * _Nullable * _Nullable)error;

/**
 * Dispatches the sweep. Returns immediately. The @c completion block fires
 * on an internal serial queue once the GPU work is fully drained into the
 * matches buffer.
 */
- (void)dispatchSweepWithCompletion:(void (^_Nullable)(NSArray<GRDMatch *> *))
    completion;

/**
 * Drains and clears the accumulated matches buffer. Thread-safe; safe to
 * call from any host thread.
 */
- (nonnull NSArray<GRDMatch *> *)drainMatches;

@end

NS_ASSUME_NONNULL_END
```

Concrete implementations:

- `GRDPubkeySweeper` — uses `metal/pubkey.metal`.
- `GRDAddressSweeper` — uses `metal/address.metal`.

#### 5.1.3 Kernel encoding strategy (`GRDKernelStrategy`)

```objc
NS_ASSUME_NONNULL_BEGIN

/**
 * Encapsulates the mode-specific pieces of a compute command:
 * pipeline-state lookup, buffer binding order, grid dimensions.
 *
 * Splitting this from @c GRDSweeper lets the sweeper own device lifecycle
 * while the strategy owns "what the kernel does."
 */
@protocol GRDKernelStrategy <NSObject>

/**
 * Returns the pipeline state for this strategy's kernel, compiled from
 * @c library.
 */
- (nullable id<MTLComputePipelineState>)
    pipelineStateForLibrary:(nonnull id<MTLLibrary>)library
                      error:(NSError * _Nullable * _Nullable)error;

/**
 * Encodes the dispatch into @c encoder. Sets buffers, dispatches the grid.
 * Does NOT call end-encoding on the encoder (caller controls the pass).
 */
- (void)encodeDispatchIn:(nonnull id<MTLComputeCommandEncoder>)encoder
                  config:(nonnull GRDConfig *)config
                   range:(nonnull GRDRange *)range;

@end

NS_ASSUME_NONNULL_END
```

#### 5.1.4 Match factory (`GRDMatchFactory`)

```objc
NS_ASSUME_NONNULL_BEGIN

/**
 * Turns raw kernel output (tid + variant index + j-bytes) into typed matches.
 * Pubkey matches carry a variant index; address matches do not.
 */
@protocol GRDMatchFactory <NSObject>

- (nonnull GRDMatch *)matchFromRaw:(nonnull GRDRawMatch *)raw;

@end

NS_ASSUME_NONNULL_END
```

#### 5.1.5 Mode router (`GRDSweeperFactory`)

```objc
NS_ASSUME_NONNULL_BEGIN

@interface GRDSweeperFactory : NSObject

/**
 * Returns the concrete @c GRDSweeper for @c config on @c device. This is
 * the only place in the codebase that switches on config.mode.
 */
+ (nullable id<GRDSweeper>)sweeperForConfig:(nonnull GRDConfig *)config
                                     device:(nonnull id<MTLDevice>)device
                                      error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
```

Adding a third mode (e.g. x-only pubkey, hash40 with prefix) requires only:

1. New `GRD*Target` conforming to `GRDTarget`.
2. New `GRD*Sweeper` conforming to `GRDSweeper`.
3. New `GRD*KernelStrategy` conforming to `GRDKernelStrategy`.
4. New `GRD*MatchFactory` conforming to `GRDMatchFactory`.
5. One new `switch` arm in `GRDSweeperFactory`.

Zero changes elsewhere.

### 5.2 Zero-Communication-Overhead Design Rules

The host↔device and inter-GPU communication paths are the throughput
ceiling for long sweeps. The following rules apply to every unit that
touches Metal dispatch or multi-device coordination:

1. **All Metal buffers use `MTLResourceStorageModeShared`** — unified memory
   on Apple Silicon gives zero-copy CPU/GPU access. Never use `MTLResourceStorageModePrivate` (we never copy explicitly).
2. **Never call `[buffer waitUntilCompleted]` in the hot path**. Use
   `[commandBuffer addCompletedHandler:^...]` for completion signalling.
3. **Double-buffer the matches output** (`matchesBufferA`, `matchesBufferB`)
   so the GPU writes to A while the CPU drains B and vice versa.
4. **Per-device buffers only during the sweep**. Cross-device merging happens
   exactly once at the end, inside `dispatch_group_t`'s notify block.
5. **Single serial host queue** for all coordinator work
   (`com.greedyfind.host`). No mutexes, no `@synchronized`, no
   `os_unfair_lock`. All host-side state mutated only from this queue.
6. **`MTLEvent` only where the GPU pipeline requires it** (e.g. variant-prune
   finishing before sweep). For all other ordering, rely on command-buffer
   completion order.
7. **No `dispatch_sync` from a background queue to the host queue** (would
   deadlock under load). Only `dispatch_async` and `dispatch_group_wait`.
8. **Per-threadgroup local match scratch** before any device-wide atomic.
   Atomics only fire on rare match events; the hot path is contention-free.
9. **`__autoreleasing` for `NSError **`** out-parameters; no exceptions.
10. **No `[obj retain]` / `[obj release]`** under ARC. Exception: `id<MTLBuffer>.contents` is a `void *` alias, used directly without memory management.
11. **No `objc_msgSend` in inner loops**. Cache `id<MTLFunction>` and
    `id<MTLComputePipelineState>` references at `init` time.
12. **Index + anchor table live in `threadgroup` memory**. No device-memory
    roundtrip per binary-search step.
13. **All `[id<NSCoding> encode…]` / `decode…`** calls (cache, checkpoint)
    use `NSData` round-trip — no property-list serialisation of large
    arrays.
14. **Number-formatted output via `[NSString stringWithFormat:]` is OK**
    in the cold path (telemetry), but the hot path emits raw integer bytes
    and formats only on match events.

---

## 6. File Layout

```
greedyfind/
├── plan.md                            # this file
├── README.md                          # quick-start (filled at A53)
├── DISCLAIMER.md                          # port from find/DISCLAIMER.md
├── LICENSE-MIT                            # port from find/LICENSE-MIT
├── .gitignore
├── .clang-format                       # Google base + project overrides
├── CMakeLists.txt                      # builds host + metallib
│
├── metal/                              # all .metal files here
│   ├── types.metal                     # secp256k1_types.metal → renamed
│   ├── secp256k1.metal                 # field, EC, scalar_mul, Montgomery
│   ├── ecdsa.metal                     # SHA-256, RIPEMD-160, hash160
│   ├── pubkey.metal                    # sweep_kernel_pubkey → renamed
│   ├── address.metal                   # sweep_kernel_address → renamed
│   ├── prune.metal                     # variant_prune → renamed
│   └── table.metal                     # table_init → renamed
│
├── host/                               # all .h / .m / .c files here
│   ├── main.m                          # CLI parsing + session lifecycle
│   ├── config.{h,m}                    # greedy_config → renamed
│   ├── ecc.{h,c}                       # greedy_ecc → renamed
│   ├── pubkey.{h,c}                    # greedy_pubkey → renamed
│   ├── address.{h,c}                   # greedy_address → renamed
│   ├── sweep.{h,m}                     # greedy_sweep → renamed
│   ├── cache.{h,c}                     # greedy_cache → renamed
│   ├── checkpoint.{h,c}                # greedy_checkpoint → renamed
│   ├── telemetry.{h,m}                 # greedy_telemetry → renamed
│   └── log.{h,m}                       # greedy_log → renamed
│
├── docs/                               # filled in A49–A53
│   ├── algorithms.md
│   ├── architecture.md
│   ├── cli.md
│   ├── configuration.md
│   └── security.md
│
├── scripts/                            # filled in A4, A33, A45–A47
│   ├── check_toolchain.sh
│   ├── run_kat.sh
│   ├── differential.sh
│   ├── cache_compat.sh
│   └── run_bench.sh
│
├── bench/                              # filled in A36–A39
│   ├── sweep_bench.m
│   └── README.md                       # how to run
│
├── tests/                              # filled across A6–A48
│   ├── kat/                            # host-driven KATs
│   ├── differential/                   # shell-driven vs find
│   └── unit/                           # host-side unit tests
│
└── examples/                           # filled in A48
    └── run.sh
```

---

## 7. Atomic Implementation Plan (54 Units)

Every unit is independently buildable, testable, and committable. Per-unit
quality gates are defined in §8.

### Phase 0 — Bootstrap (Units A1–A5)

| # | Unit | Files | Commit message |
|---|---|---|---|
| A1 | Repo init: set local `user.name=sachin`, `user.email=sachncs@gmail.com`, create initial commit. | `.git/config` (local) | `chore: initialize greedyfind repository` |
| A2 | Tree + `.gitignore` + `.clang-format` | `metal/`, `host/`, `docs/`, `scripts/`, `bench/`, `tests/`, `examples/`, `.gitignore`, `.clang-format` | `chore: scaffold directory tree and style config` |
| A3 | Legal docs | `README.md` (stub), `DISCLAIMER.md`, `LICENSE-MIT` | `docs: add disclaimer and license` |
| A4 | Toolchain check | `scripts/check_toolchain.sh` | `build: add xcrun metal prereq check` |
| A5 | CMake skeleton | `CMakeLists.txt`, empty `host/main.m` | `build: cmake skeleton compiles empty binary` |

### Phase 1 — Field and Point Arithmetic (Units A6–A15)

| # | Unit | Files | Commit message |
|---|---|---|---|
| A6 | `types.metal` — `EcPoint`, `EcScalar`, secp256k1 `p`, `n`, `G`, `B256` constants. | `metal/types.metal` | `metal: add secp256k1 types and constants` |
| A7 | `field_add` / `field_sub` with carry. | `metal/secp256k1.metal`, `tests/kat/field_kat.c` | `metal: implement field add and sub` |
| A8 | `field_mul` — 4×4 schoolbook + Montgomery reduction. | `metal/secp256k1.metal`, `tests/kat/field_kat.c` | `metal: implement field multiplication` |
| A9 | `field_sqr` — verified via `field_mul(a, a)`. | `metal/secp256k1.metal` | `metal: implement field squaring` |
| A10 | `field_inv` via Fermat `a^(p-2)`. | `metal/secp256k1.metal` | `metal: implement field inversion via Fermat` |
| A11 | `ec_double` (Jacobian doubling). | `metal/secp256k1.metal`, `tests/kat/ec_kat.c` | `metal: implement point doubling` |
| A12 | `ec_add`, `ec_add_mixed`, `ec_neg`. | `metal/secp256k1.metal` | `metal: implement point addition and negation` |
| A13 | Montgomery batch inversion (per threadgroup). | `metal/secp256k1.metal` | `metal: implement Montgomery batch inversion` |
| A14 | `scalar_mul` (binary double-and-add). | `metal/secp256k1.metal` | `metal: implement scalar multiplication` |
| A15 | `reduce_uint256_mod_n` (secp256k1 fast reduction). | `metal/secp256k1.metal` | `metal: implement secp256k1 order reduction` |

### Phase 2 — Hash Primitives (Units A16–A19)

| # | Unit | Files | Commit message |
|---|---|---|---|
| A16 | u128 helpers (`add`, `sub`, `cmp`, `toDecimal`, `decimalToU128`). | `host/ecc.{h,c}`, `tests/unit/u128_test.c` | `host: add u128 arithmetic helpers` |
| A17 | SHA-256 (RFC 4634 / FIPS 180-4). | `metal/ecdsa.metal`, `tests/kat/sha256_kat.c` | `metal: implement SHA-256` |
| A18 | RIPEMD-160 (RFC 2286 / Bosselaers). | `metal/ecdsa.metal`, `tests/kat/ripemd_kat.c` | `metal: implement RIPEMD-160` |
| A19 | `hash160_compressed(point)` — SHA-256 → RIPEMD-160 of 33-byte compressed pubkey. | `metal/ecdsa.metal`, `tests/kat/hash160_kat.c` | `metal: implement hash160 over compressed point` |

### Phase 3 — CPU Variant Generation (Units A20–A22)

| # | Unit | Files | Commit message |
|---|---|---|---|
| A20 | `generate_variants` — 512 variants (powers-of-two + cumulative sums), interned via `pthread_once`. | `host/pubkey.{h,c}` | `host: implement variant metadata (512 variants)` |
| A21 | `compute_variant_x_bytes` — target-dependent 512 X-coords. | `host/pubkey.{h,c}` | `host: implement variant X-coordinate computation` |
| A22 | `VariantIndex` — sort + permutation, 16 KiB L1-resident. | `host/pubkey.{h,c}`, `tests/kat/variant_index_kat.c` | `host: implement variant index with sort and permutation` |

### Phase 4 — Address Decode (Unit A23)

| # | Unit | Files | Commit message |
|---|---|---|---|
| A23 | base58check P2PKH mainnet decoder. | `host/address.{h,c}`, `tests/kat/address_decode_kat.c` | `host: implement base58check P2PKH decoder` |

### Phase 5 — Device Kernels (Units A24–A28)

| # | Unit | Files | Commit message |
|---|---|---|---|
| A24 | `prune.metal` — 512 threads write productivity bitmap for `[from, to)` (general u128 integers). | `metal/prune.metal`, `tests/kat/prune_kat.metal` | `metal: implement device-side variant pruning` |
| A25 | `table.metal` — anchor init kernel: `(from + i*step)·G` for each anchor slot. | `metal/table.metal`, `tests/kat/anchor_kat.metal` | `metal: implement anchor table initialisation` |
| A26 | `pubkey.metal` — single-threadgroup smoke sweep kernel. | `metal/pubkey.metal` | `metal: implement pubkey sweep kernel` |
| A27 | `address.metal` — single-threadgroup smoke sweep kernel. | `metal/address.metal` | `metal: implement address sweep kernel` |
| A28 | Both kernels bootstrap from anchor table (vs. linear-from-zero). | `metal/pubkey.metal`, `metal/address.metal` | `metal: bootstrap sweep from anchor table` |

### Phase 6 — Host Dispatch (Units A29–A32)

| # | Unit | Files | Commit message |
|---|---|---|---|
| A29 | `GRDSweeper` base + single-device dispatch path. | `host/sweep.{h,m}` | `host: implement GRDSweeper with single-device dispatch` |
| A30 | `GRDSweeperFactory` mode router. | `host/sweep.{h,m}`, `host/main.m` | `host: add mode router via protocol factory` |
| A31 | `MTLCopyAllDevices()` enumeration. | `host/sweep.{h,m}` | `host: enumerate all Metal devices` |
| A32 | `dispatch_group_t` multi-GPU fan-out + result merge. | `host/sweep.{h,m}` | `host: coordinate multi-GPU sweep via dispatch_group` |

### Phase 7 — Persistence and Observability (Units A33–A35)

| # | Unit | Files | Commit message |
|---|---|---|---|
| A33 | Binary cache (byte-compatible with `find`). | `host/cache.{h,c}`, `scripts/cache_compat.sh` | `host: implement binary cache with find byte-compat` |
| A34 | Atomic checkpoint (write-then-rename, integrity anchor). | `host/checkpoint.{h,c}` | `host: implement atomic checkpoint with integrity anchor` |
| A35 | NDJSON telemetry + rolling text log. | `host/telemetry.{h,m}`, `host/log.{h,m}` | `host: implement NDJSON telemetry and rolling log` |

### Phase 8 — Microbench + Autotune (Units A36–A39)

| # | Unit | Files | Commit message |
|---|---|---|---|
| A36 | `bench/sweep_bench.m` — sweep throughput harness (j/sec, EC_adds/sec). | `bench/sweep_bench.m`, `bench/README.md` | `bench: add sweep throughput microbench` |
| A37 | Threadgroup size autotune (16 / 32 / 64 / 128 lanes). | `bench/sweep_bench.m` | `bench: autotune threadgroup size` |
| A38 | Anchor interval autotune (`2^12` / `2^14` / `2^16` / `2^18` / `2^20`). | `bench/sweep_bench.m` | `bench: autotune anchor interval` |
| A39 | Variant count autotune (256 / 512). | `bench/sweep_bench.m` | `bench: autotune variant count` |

### Phase 9 — Throughput Optimisation (Units A40–A44)

Every optimisation has a **measured-revert rule**: keep iff ≥5% speedup vs.
the prior unit, otherwise document why and revert.

| # | Unit | Files | Commit message |
|---|---|---|---|
| A40 | `simd_*` intrinsics for batch Montgomery inversion. | `metal/secp256k1.metal` | `metal: optimise batch inversion with simdgroup intrinsics` |
| A41 | Command-buffer pipelining (multiple in-flight buffers). | `host/sweep.{h,m}` | `host: pipeline command buffers for overlap` |
| A42 | Per-threadgroup local match buffer + coalesced device write. | `metal/pubkey.metal`, `metal/address.metal` | `metal: coalesce match output per threadgroup` |
| A43 | 8-byte prefix index for first binary-search pass. | `metal/pubkey.metal` | `metal: 8-byte prefix index for first binary-search pass` |
| A44 | Dynamic load rebalancing across GPUs. | `host/sweep.{h,m}` | `host: dynamic load rebalancing across GPUs` |

### Phase 10 — End-to-End Verification (Units A45–A48)

| # | Unit | Files | Commit message |
|---|---|---|---|
| A45 | KAT runner script. | `scripts/run_kat.sh` | `test: add KAT runner script` |
| A46 | Differential script vs `find` Rust crate. | `scripts/differential.sh` | `test: add differential against find crate` |
| A47 | Throughput regression gate (≥5% baseline). | `scripts/run_bench.sh`, `benchmarks/baseline_*.json` | `ci: throughput regression gate` |
| A48 | End-to-end smoke (both modes). | `examples/run.sh` | `test: end-to-end smoke for both modes` |

### Phase 11 — Documentation (Units A49–A53)

| # | Unit | Files | Commit message |
|---|---|---|---|
| A49 | `docs/algorithms.md` — range-splitting math, pruning spec. | `docs/algorithms.md` | `docs: describe range-splitting math and pruning` |
| A50 | `docs/architecture.md` — host↔device pipeline, kernel grid. | `docs/architecture.md` | `docs: describe host-device pipeline and kernel grid` |
| A51 | `docs/cli.md` + `docs/configuration.md`. | `docs/cli.md`, `docs/configuration.md` | `docs: flag reference with examples` |
| A52 | `docs/security.md` — threat model. | `docs/security.md` | `docs: threat model and research-only disclaimer` |
| A53 | README quick-start. | `README.md` | `docs: README quick-start for both modes` |

### Phase 12 — Release (Unit A54)

| # | Unit | Files | Commit message |
|---|---|---|---|
| A54 | Tag v0.1.0. | git tag | `release: tag v0.1.0` |

---

## 8. Per-Unit Quality Gates

Every unit must satisfy all four gates before being marked complete.

### Gate 1 — Build clean

```bash
cmake --build build -j 2>&1 | tee /tmp/build.log
```

- Zero warnings under `-Wall -Wextra -Wpedantic -Werror`.
- `grep -c 'warning:' /tmp/build.log` returns 0.
- For `.metal` changes, the metallib step also succeeds.

### Gate 2 — Style clean

```bash
clang-format --style=file -i <modified-files>
git diff --exit-code -- <modified-files>
```

- Zero diff after format.
- Metal files (formatted by hand) reviewed by a second pass of the author.

### Gate 3 — KAT pass

```bash
bash scripts/run_kat.sh
```

- Every test in `tests/kat/*` runs green.
- For a new KAT, the test file is added to `scripts/run_kat.sh` before commit.

### Gate 4 — Commit hygiene

- Single focused commit.
- Subject ≤ 72 chars.
- Imperative mood (`add`, not `added`).
- Body explains *what* and *why*, not *how*.
- Author is `sachin <sachncs@gmail.com>` (verified via `git log -1 --format='%an <%ae>'`).

---

## 9. Verification Matrix

| Category | Test | Trigger |
|---|---|---|
| **Field ops** | `tests/kat/field_kat.c` — 100+ known-answer vectors for add/sub/mul/sqr/inv | A8–A10 |
| **EC ops** | `tests/kat/ec_kat.c` — 200+ known-answer vectors for double/add/neg; identity checks | A11–A13 |
| **Scalar mul** | `tests/kat/scalar_kat.metal` — `scalar_mul(k, G)` matches reference for `k ∈ {1..1000}` | A14 |
| **Reduction mod n** | `tests/kat/reduce_kat.c` — 100 vectors including `2^256 - 1`, `n - 1`, `n + 1` | A15 |
| **u128 helpers** | `tests/unit/u128_test.c` — 200 vectors for add/sub/cmp/parse/format | A16 |
| **SHA-256** | `tests/kat/sha256_kat.c` — 64 NIST CAVP short-message vectors | A17 |
| **RIPEMD-160** | `tests/kat/ripemd_kat.c` — 64 RFC 2286 / Bosselaers vectors | A18 |
| **hash160** | `tests/kat/hash160_kat.c` — known hash160 values for Genesis coinbase + Bitcoin puzzle addresses | A19 |
| **Variant generation** | `tests/differential/variants.sh` — byte-identical to `find/src/search.rs:610-676` for 100 random `P` | A20–A21 |
| **Variant index** | `tests/kat/variant_index_kat.c` — `match_x(x, j)` returns expected `GRDMatch` for fixtures | A22 |
| **Address decode** | `tests/kat/address_decode_kat.c` — 10 known P2PKH addresses round-trip | A23 |
| **Variant pruning** | `tests/kat/prune_kat.metal` — `[2^70, 2^71)` → 141/512 productive; `[1, 1000)` → 18/512; `[12345, 67890]` → 28/512 | A24 |
| **Anchor init** | `tests/kat/anchor_kat.metal` — each anchor = `(from + i*step)·G` | A25 |
| **Sweep smoke (pubkey)** | `--pubkey <(2^70+12345)·G> --from 1180591620717411303424 --to 1180591620717411303524` → `[2^70+12345, n-...]` in <1 min | A26, A28 |
| **Sweep smoke (address)** | `--address <P2PKH(2^70+54321)> --from 1180591620717411303424 --to 1180591620717411303524` → `2^70+54321` in <1 min | A27, A28 |
| **Host dispatch** | Both smoke tests pass through `GRDSweeperFactory` | A29–A30 |
| **Multi-GPU scaling** | 2+ GPU host — total throughput within 5% of `N × single-GPU` | A31–A32 |
| **Cache compat** | Pre-generate cache with `find`, scan with `greedyfind`; outputs match | A33 |
| **Checkpoint resume** | `kill -TERM` mid-sweep, restart with `--resume`; continuity preserved | A34 |
| **Telemetry** | `tests/unit/telemetry_kat.m` — emitted NDJSON events match schema | A35 |
| **Throughput regression** | Bench baseline on M3 Pro; CI fails if >5% drop | A47 |
| **End-to-end smoke** | `examples/run.sh` runs both modes on known targets | A48 |

---

## 10. Throughput

The reference range `[2^70, 2^71)` requires `2^70 ≈ 1.18 × 10^21` EC
operations. Anchor tables every `2^16` threadgroups cut bootstrap scalar muls
from `2^65` to `2^49`. The repo does not project throughput; run
`bench/sweep_bench` on the target host and use the measured j/sec to
estimate wall-clock for any specific range and device count.

Both modes are dominated by EC adds. Hashing adds a fixed ~15–25% per-`j`
overhead but no new asymptotics. The tool is designed as a long-running
daemon with checkpoint+resume — nobody runs it interactively.

Optimisation units A40–A44 target cumulative ≥30% throughput improvement over
the A36 baseline. Each unit is measured; reverting if below threshold.

---

## 11. Risks

| # | Risk | Probability | Impact | Mitigation |
|---|---|---|---|---|
| 1 | **Xcode missing on this host** — only CommandLineTools is installed today | High (already true) | Blocks A4+ | `scripts/check_toolchain.sh` fails fast with a clear message; user installs full Xcode before configuring |
| 2 | **Threadgroup memory ceiling (32 KiB on Apple Silicon)** — variant index (16 KiB) + scratch + +G table + hash state | Medium | Kernel won't compile or spills to slow memory | Variant count autotune (A39) falls back to 256 variants (8 KiB index) if needed |
| 3 | **Hash correctness** — SHA-256 and RIPEMD-160 are subtle bit-fiddly primitives | Medium | Wrong candidates reported as matches | KAT against RFC vectors at A17–A19 before any kernel integration |
| 4 | **Multi-GPU merge race** | Low | Spurious double-count or missing matches | Per-device `matches` buffers; merge in single `dispatch_group` notify block (A32) |
| 5 | **Optimisation regressions** (A40–A44) | Medium | Net throughput loss | Each unit has a measured-revert rule (≥5% speedup or revert) |
| 6 | **Range arithmetic generalisation** — `from`/`to` are arbitrary u128 integers, not power-of-2 | Low | Off-by-one or wraparound bugs | All range math in u128 throughout; no power-of-2 special-casing; property tests in A16 |
| 7 | **Address Y-parity requires full affine Y** — Montgomery inv per threadgroup | Low | Extra cost; not a correctness issue | Inversion already amortised across 32 lanes; net cost = 1/32 inv per `j` |
| 8 | **Device-only variant pruning** — uploads all 16 KiB regardless of range | Low | Higher GPU memory than necessary (still fits) | Acceptable trade-off per user direction; variant count autotune (A39) adjusts the count itself |
| 9 | **Atomic unit count is high (54)** | Low | Long implementation runway | Each unit is small (<2 hrs typical); build+test gates per unit keep progress green |
| 10 | **Remote configured as `sachncs/greedy-find`** (note hyphen) but local dir is `greedyfind` (no hyphen) | Low | Confusion only | Documented in README; no functional consequence |
| 11 | **Double-buffer matches — risk of GPU/CPU reading same buffer** | Medium | Spurious matches or missed matches | Buffer swap happens only in completion handlers on the serial host queue; CPU readback precedes dispatch on the other buffer (strict ordering) |
| 12 | **`dispatch_group_t` retention** across long sweeps | Low | Memory growth | One `dispatch_group_t` per session, released at session end |

---

## 12. Locked Decisions

These are not subject to further revision without an explicit reopen:

| Item | Locked value |
|---|---|
| Repository location | `/Users/sachin/repo/greedyfind/` |
| Git remote | `https://github.com/sachncs/greedy-find.git` |
| Git author (repo-local) | `sachin <sachncs@gmail.com>` |
| Default branch | `master` |
| Host language | Objective-C + C (no Swift, no C++ in host) |
| GPU language | Metal Shading Language (`metal3.0`) |
| GPU target | Apple Silicon only (M1–M4); `MTLCopyAllDevices()` by default |
| Build system | CMake ≥ 3.25 + `xcrun metal` CLI |
| Coding style | Google Objective-C Style Guide + `GRD` prefix |
| Polymorphism | Five protocols (§5.1); one `switch` in `GRDSweeperFactory` |
| Storage mode | All buffers `MTLResourceStorageModeShared` |
| Completion signalling | `addCompletedHandler:` only; no `waitUntilCompleted` in hot path |
| Mutex usage | None — serial dispatch queue only |
| Exception usage | None — `NSError **` out-parameters only |
| Variant count default | 512; `--variants` exposed (256 / 512 supported) |
| Anchor interval default | `2^16` threadgroups; `--anchor-interval` exposed |
| Address types | P2PKH mainnet only (version byte `0x00`) |
| Y-parity | Affine Y parity from Montgomery inv |
| Range parsing | Arbitrary unsigned decimal integers parsed via `decimal_to_u128` |
| Range storage | `uint128_t` throughout (no power-of-2 special paths) |
| Cache format | Byte-compatible with `find/docs/adr/0006-binary-cache-format.md` |
| Telemetry | NDJSON + rolling text log |
| Variant pruning | Device-only via `metal/prune.metal` (no CPU-side pruner) |
| Per-mode kernels | `metal/pubkey.metal`, `metal/address.metal` (no shared kernel file) |
| Reference test range | `[2^70, 2^71)` with known targets `d = 2^70 + 12345` (pubkey) and `d = 2^70 + 54321` (address) |
| Optimisation gate | Keep each A40–A44 iff ≥5% j/sec improvement vs prior unit |
| Per-unit quality gates | Four gates: build clean, style clean, KAT pass, commit hygiene |

---

*Plan version: 1.0 · Generated for build-mode execution · Commit author: `sachin <sachncs@gmail.com>`*