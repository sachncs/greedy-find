# algorithms.md — range-splitting math and pruning

`greedyfind` searches a range `[from, to)` of private-key candidates
`j` for one whose associated public key matches a target. The
algorithm is the same as the [`find`](https://github.com/sachncs/find)
crate's: **multi-variant range-splitting** with **per-anchor batch
inversion** and **X-coordinate pruning**.

## 1. The two target relations

For a target public key `P` with X-coordinate `x_P` and a target
address `A` with hash160 `h_A = hash160(P)`:

```
pubkey mode  : x(j · G) == x(P - V · G)        for some V
address mode : hash160(j · G) == h_A
```

`V` is a small "variant" offset drawn from a fixed 512-element
table. Each entry in the table lets the kernel test a different
candidate for the same `j`, multiplying the effective search
breadth per `j` by 512.

## 2. The variant table

The variant table has 512 entries. The first 256 are powers of
two mod `n`:

```
V[0..256) = (1, 2, 4, 8, ..., 2^255) mod n
```

The second 256 are cumulative sums:

```
V[256..512) = (1, 1+2, 1+2+4, ..., 2^256 - 1) mod n
```

For each `j` the kernel tests both `j + V` and `j - V` (i.e.
`P + V·G` and `P - V·G`), so the 512 entries cover both signs.

## 3. Anchor tables

The host precomputes an "anchor" every `2^k` threadgroups: the
projective point `(j·G, j·G + G, j·G + 2·G, ...)`. Each thread
group then takes the next anchor in the table and continues the
EC-add chain from there. This amortises the per-`j` cost over
the batch:

- batch size `B` (default 32) — `B` j's per threadgroup.
- anchor interval `2^k` threadgroups — anchor refresh cost is
  spread over `2^k · B` j's.

A larger `B` reduces EC-add overhead per j; a larger anchor
interval reduces host-side precomputation but increases the
per-anchor additive cost (the chain has to walk further between
anchors). The autotune in `bench/sweep_bench` finds the per-axis
optimum.

## 4. Per-threadgroup batch inversion

Projective EC points keep the Z coordinate symbolic. Converting
back to affine (which the X-compare needs) requires one field
inversion per point, which is expensive (a modular exponentiation
in the field).

A standard trick — Montgomery's batch inversion — computes `n`
inversions for the cost of one inversion plus `3(n - 1)`
multiplications. The kernel:

1. Accumulates `acc[i] = Z[0] · Z[1] · ... · Z[i]`.
2. Computes `inv = acc[n-1]^{-1}` (one expensive inversion).
3. Walks back: `Z[i]^{-1} = acc[i-1] · inv`, then `inv = acc[i-1] · inv`.

For `n = 32` (one threadgroup's lanes) the savings are ~32× over
naive per-point inversion. See `metal/secp256k1.metal::grdBatchInvert`
for the implementation and `metal/secp256k1_simd.metal` for the
A40 simdgroup variant.

## 5. Pruning the variant space

For each variant `V`, the kernel checks a "productivity" bit
before the full EC add. The bit is set by a one-time
host-side prune (`grdVariantPrune`) that precomputes
`x(P - V·G) mod n` for each `V` and confirms the result is
in the curve's valid subgroup. Variants whose target is at the
identity are dropped (their compare would always be 0).

The productivity bitmap is 64 bytes (512 bits), uploaded once
per sweep, and lives in threadgroup memory in the inner loop.

## 6. Why X-coordinate compare (not full key)?

Compressed SEC1 public keys carry only the X coordinate plus a
parity bit for Y. For a target `P`, the kernel computes
`x(j·G) = X(j·G)` and compares it to `x_P`. A match in X has
two candidate Y values (`+y` and `-y`); both produce valid
public keys, so a single match in --pubkey mode yields two
candidate private keys `d = j ± V mod n`.

In --address mode the kernel goes one step further: it computes
the full compressed pubkey from `X`, `Y`, then `hash160(compressed)`
and compares to the target. This is more expensive per match
(must do the SHA-256 + RIPEMD-160 in-kernel) but is necessary
when only the address is known.

## 7. Reference: range for v0.1

`plan.md` locks the reference range to `[2^70, 2^71)`, a
Bitcoin Puzzle #71-style search space. The full range is
~10^21 j; at the projected M-series throughput of ~10^8 j/sec
that's ~10^13 seconds — well beyond the lifetime of any single
machine. The realistic use is a partial sweep: a co-operative
network of machines each takes a `[2^70 + k·2^k, ...)` slice,
each maintains its own checkpoint, and matches are recovered
via NDJSON telemetry.
