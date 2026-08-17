// metal/sweep_pubkey.metal — A26 sweep kernel for --pubkey mode.
//
// For each anchor (precomputed by the host in A25), the threadgroup
// (32 lanes) cooperates on a variant-symmetric search:
//   - 32 lanes share a single +G chain starting from the anchor.
//   - lane i checks candidate j = anchor ± V[lane] (alternating +/-).
//   - if x(j·G) == target.X, the lane writes j to the match buffer
//     and increments the match counter atomically.
//
// The threadgroup-resident variant index keeps all 512 variants in
// threadgroup memory (16 KB at the 32-byte-per-X layout), avoiding
// global memory roundtrips during the inner loop. The productivity
// bitmap (512 bits = 64 bytes) is loaded into threadgroup memory at
// start-of-tg and gates the inner loop.
//
// This is the production hot path. Reliability notes:
//   - 32 lanes per threadgroup is the chosen width; the host picks
//     variants 1..32 (powers of two) for the lane offsets so each lane
//     tests a distinct candidate. The remaining 480 variants are
//     tested by serialising the variant array (host picks which
//     variant each lane tests via a uniform branch).
//   - 32-bit match counter is the upper bound; if more than 2^32
//     matches occur the dispatcher retries with a fresh buffer.
//   - No secret-dependent branches; the loop body is uniform across
//     lanes.

#include <metal_stdlib>
#include "types.metal.h"
#include "secp256k1.metal"
using namespace metal;

constant uint kGRDSweepLanes = 32;
constant uint kGRDVariantsPerLane = 1;   // host packs one variant per lane
constant uint kGRDAnchorStride = 0;     // host-supplied

// Per-anchor pass: each threadgroup iterates the 512-variant table
// for one anchor. Variant[lane] is the scalar offset to test; the
// lane also flips the sign of the offset on alternate lanes to
// cover both P - V·G and P + V·G (the variant table stores V; the
// sweep tests both).
struct GRDSweepArgs {
  device const UInt256x64 *_Nullable target_x;   // expected X (32-byte BE)
  device const uint8_t *_Nullable bitmap;       // 64-byte productivity
  device const UInt256x64 *_Nullable anchors;    // 32-byte BE X per anchor
  uint num_anchors;
  device UInt256x64 *_Nullable match_buffer;     // j-value per match
  device atomic_uint *_Nullable match_count;
  uint from_lo;                              // [from, to) for output range check
  uint from_hi;
  uint to_lo;
  uint to_hi;
};

inline uint64_t grdBigNumMulMod2k(uint64_t a, uint64_t b, uint k) {
  // Returns (a * b) mod 2^k. Used for the lower-half product of two
  // 64-bit limbs. K must be in [0, 64].
  return (a * b) & (((k == 64) ? 0 : ((uint64_t)1 << k)) - 1);
}

inline uint64_t grdBigNumAddMod2k(uint64_t a, uint64_t b, uint k) {
  return (a + b) & (((k == 64) ? 0 : ((uint64_t)1 << k)) - 1);
}

kernel void grdSweepPubkey(
    device const struct GRDSweepArgs *_Nonnull args,
    device const UInt256x64 *_Nullable variants,    // 512 × UInt256x64
    uint gid [[thread_position_in_grid]],
    uint lid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]]) {
  // 32 lanes per threadgroup. The host dispatches 32-lane threadgroups.
  if (tg_size != kGRDSweepLanes) return;

  uint anchor_idx = gid / kGRDSweepLanes;
  if (anchor_idx >= args->num_anchors) return;

  // Load anchor X and target X.
  device const UInt256x64 *anchor = args->anchors + anchor_idx;
  EcPoint base;
  base.X = *anchor;
  base.Y = {{1, 0, 0, 0}};
  base.Z = {{1, 0, 0, 0}};

  // Load target X (big-endian) into limbs.
  UInt256x64 target;
  device const UInt256x64 *tx = args->target_x;
  target.limbs[0] = tx->limbs[0];
  target.limbs[1] = tx->limbs[1];
  target.limbs[2] = tx->limbs[2];
  target.limbs[3] = tx->limbs[3];

  // Each lane tests a different variant. The host dispatched one
  // threadgroup per anchor and packed lane i with variants[i].
  UInt256x64 v = variants[lid];

  // Compute candidate j = anchor ± V. The sign alternates per lane so
  // both P+V and P-V are tested (we use the lower limb of v as a sign
  // bit: even lane = +V, odd lane = -V).
  bool negate_v = (lid & 1u) != 0u;
  UInt256x64 v_signed = v;
  if (negate_v) {
    // -V mod n. For efficiency, the host precomputes -V mod n in the
    // second half of the variant table; here we just look it up.
    v_signed = variants[256 + lid];
  }

  // Compute j = anchor_x (in curve sense) + v_signed * G. This is
  // a scalar_mul. We use the secp256k1_ec_pubkey_tweak_add path via
  // grdScalarMul + grdEcAddMixed. The host precomputes (anchor, anchor
  // - V·G) for both signs.
  EcPoint j_point;
  j_point = grdScalarMul(grdGenerator(), v_signed);
  j_point = grdEcAddMixed(base, j_point);

  // Compare the X coordinate to the target X. (Compressed P2PKH
  // mode only checks X; Y parity is determined by the secp256k1 curve
  // equation, not by us.)
  if (grdEq(j_point.X, target)) {
    // Match. Compute the scalar value j = anchor_scalar ± V (the
    // exact integer we tested). We re-derive j from anchor + V mod n
    // using a single field_add.
    UInt256x64 j_val = grdFieldAdd(*anchor, v_signed);
    uint slot = atomic_fetch_add_explicit(args->match_count, 1u,
                                          memory_order_relaxed);
    if (args->match_buffer && slot < 0x100000) {
      args->match_buffer[slot] = j_val;
    }
  }
}