// metal/sweep_pubkey.metal — A26 sweep kernel for --pubkey mode.
//
// Path C2: full-point anchor table + precomputed V·G. The host
// precomputes (from + i)·G for each i in [0, num_anchors) using
// libsecp256k1 and uploads the points as a 96-byte-per-anchor table.
// It also precomputes V[k]·G for each of the 512 variants and uploads
// those. The kernel reads anchor[j_idx] as a full EcPoint and
// v_points[chunk * 32 + lid] as a full EcPoint, then performs one
// grdEcAddMixed per lane to compute the candidate (j + V)·G.
//
// Per-lane cost: ONE EC add + ONE X comparison. No scalar muls on the
// GPU. Total per-threadgroup cost: 32 EC adds. Total per-slice cost
// (with num_anchors ≤ 2^20 and 16 chunks): ~16 × num_anchors × 32 EC
// adds, dominated by the per-anchor work. For [0, 1M) this is on the
// order of 5 × 10^8 EC adds, which an M-series GPU handles in seconds.
//
// Reliability notes:
//   - 32 lanes per threadgroup, each testing one variant.
//   - 16 threadgroups per j (chunks 0..15), so the full 512-variant
//     table is covered across the 16 threadgroups.
//   - Each lane stores the candidate (j + V) when X matches; the
//     host's recovery formula is d = j + V or d = j − V (mod n).
//   - 32-bit match counter; if more than 2^32 matches occur the host
//     retries with a fresh buffer.

#include <metal_stdlib>
#include "types.metal.h"
#include "secp256k1.metal"
using namespace metal;

constant uint kGRDSweepLanes     = 32;
constant uint kGRDVariantsTotal  = 512;
constant uint kGRDVariantChunks  = kGRDVariantsTotal / kGRDSweepLanes;  // 16

// Sweep args struct. Layout matches host/sweeper.m::GRDSweepArgsHost
// (Tier-2 argument buffer; pointer slots are gpuAddress values):
//   offset  0: device const UInt256x64* target_x
//   offset  8: device const uint8_t*     bitmap
//   offset 16: device const EcPoint*     anchors   (full X, Y, Z per anchor)
//   offset 24: uint num_anchors
//   offset 32: device EcPoint*           v_points  (V·G per variant)
//   offset 40: device EcPoint*           match_buffer  (one slot per match)
//   offset 48: device atomic_uint*       match_count
//   offset 56: uint from_limbs[4]        (u128 little-endian, host writes only)
//   offset 72: uint to_limbs[4]          (u128 little-endian, host writes only)
// total: 88 bytes
struct GRDSweepArgs {
  device const UInt256x64 *_Nullable target_x;
  device const uint8_t     *_Nullable bitmap;
  device const EcPoint     *_Nullable anchors;
  uint                            num_anchors;
  device const EcPoint     *_Nullable v_points;
  device UInt256x64       *_Nullable match_buffer;
  device atomic_uint      *_Nullable match_count;
  uint                            from_limbs[4];
  uint                            to_limbs[4];
};

kernel void grdSweepPubkey(
    device const struct GRDSweepArgs *_Nonnull args,
    uint gid [[thread_position_in_grid]],
    uint lid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]]) {
  if (tg_size != kGRDSweepLanes) return;

  // Decompose gid into (j_idx, chunk_idx). 16 threadgroups per j.
  uint j_idx     = gid / kGRDVariantChunks;
  uint chunk_idx = gid % kGRDVariantChunks;
  if (j_idx >= args->num_anchors) return;

  // Load the precomputed anchor point for this j. The host uploaded
  // anchors[j_idx] = (from + j_idx)·G as a full EcPoint.
  EcPoint anchor = args->anchors[j_idx];

  // Each lane uses the precomputed V[lane]·G for its chunk.
  uint variant_idx = chunk_idx * kGRDSweepLanes + lid;
  EcPoint vG = args->v_points[variant_idx];

  // candidate = (j + V) · G = j·G + V·G.
  EcPoint candidate = grdEcAddMixed(anchor, vG);

  // Compare X to target.
  UInt256x64 target;
  target.limbs[0] = args->target_x->limbs[0];
  target.limbs[1] = args->target_x->limbs[1];
  target.limbs[2] = args->target_x->limbs[2];
  target.limbs[3] = args->target_x->limbs[3];

  if (grdEq(candidate.X, target)) {
    // Store the candidate scalar j + V (host derives j from the
    // anchor table index; we store the j_idx + variant_idx offset
    // here as a UInt256x64 — the host reconstructs the full scalar
    // for recovery).
    // For now, store the anchor index as a small u256 marker; the
    // host can derive d = (anchor_idx + variant_offset) mod n.
    UInt256x64 matched;
    matched.limbs[0] = (uint64_t)j_idx * (uint64_t)kGRDVariantsTotal +
                        (uint64_t)variant_idx;
    matched.limbs[1] = 0;
    matched.limbs[2] = 0;
    matched.limbs[3] = 0;
    uint slot = atomic_fetch_add_explicit(args->match_count, 1u,
                                          memory_order_relaxed);
    if (args->match_buffer && slot < 0x100000) {
      args->match_buffer[slot] = matched;
    }
  }
}
