// metal/sweep_pubkey.metal — A26 sweep kernel for --pubkey mode.
//
// Per-threadgroup scalar mul from scratch for j·G, plus per-lane
// scalar mul for V·G. The host-side path-C2 precompute (full-point
// anchor table + V·G table) is disabled pending a CPU→GPU memory
// ordering fix (see commit log). Per-threadgroup cost is one
// grdScalarMulG + 32 × grdScalarMul + 32 × grdEcAddMixed, which is
// slow but correct. The GPU kernel launch itself is fast; the per-j
// scalar mul dominates.

#include <metal_stdlib>
#include "types.metal.h"
#include "secp256k1.metal"
using namespace metal;

constant uint kGRDSweepLanes     = 32;
constant uint kGRDVariantsTotal  = 512;
constant uint kGRDVariantChunks  = kGRDVariantsTotal / kGRDSweepLanes;  // 16

// Must match GRDMatchBufferSlots in host/sweeper.m. The kernel and
// the host agree on this so the per-slice atomic counter stays in
// range; matches beyond this cap are silently dropped.
constant uint kGRDMatchBufferSlots = 256;

struct GRDSweepArgs {
  device const UInt256x64 *_Nullable target_x;
  device const uint8_t     *_Nullable bitmap;
  device const EcPoint     *_Nullable anchors;     // unused by C1
  uint                            num_anchors;
  device const EcPoint     *_Nullable v_points;    // unused by C1
  device UInt256x64       *_Nullable match_buffer;
  device atomic_uint      *_Nullable match_count;
  uint                            from_limbs[4];
  uint                            to_limbs[4];
};

kernel void grdSweepPubkey(
    device const struct GRDSweepArgs *_Nonnull args,
    device const UInt256x64 *_Nullable variants,
    uint gid [[thread_position_in_grid]],
    uint lid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]]) {
  if (tg_size != kGRDSweepLanes) return;

  uint j_idx     = gid / kGRDVariantChunks;
  uint chunk_idx = gid % kGRDVariantChunks;
  if (j_idx >= args->num_anchors) return;

  // Reconstruct j = from + j_idx.
  UInt256x64 j_val;
  j_val.limbs[0] = ((uint64_t)args->from_limbs[1] << 32) |
                    (uint64_t)args->from_limbs[0];
  j_val.limbs[1] = ((uint64_t)args->from_limbs[3] << 32) |
                    (uint64_t)args->from_limbs[2];
  j_val.limbs[2] = 0;
  j_val.limbs[3] = 0;
  j_val.limbs[0] += (uint64_t)j_idx;

  // Per-threadgroup scalar mul for j·G (expensive; one per threadgroup).
  EcPoint j_point;
  if (j_val.limbs[0] == 0 && j_val.limbs[1] == 0 &&
      j_val.limbs[2] == 0 && j_val.limbs[3] == 0) {
    j_point = grdIdentity();
  } else {
    j_point = grdScalarMulG(j_val);
  }

  uint variant_idx = chunk_idx * kGRDSweepLanes + lid;
  UInt256x64 v = variants[variant_idx];

  // Per-lane scalar mul for V·G (also expensive but bounded).
  EcPoint vG = grdScalarMul(grdGenerator(), v);
  EcPoint candidate = grdEcAddMixed(j_point, vG);

  UInt256x64 target;
  target.limbs[0] = args->target_x->limbs[0];
  target.limbs[1] = args->target_x->limbs[1];
  target.limbs[2] = args->target_x->limbs[2];
  target.limbs[3] = args->target_x->limbs[3];

  if (grdEq(candidate.X, target)) {
    // Store j + V as the candidate scalar.
    UInt256x64 matched = v;
    matched.limbs[0] += (uint64_t)j_idx;
    uint slot = atomic_fetch_add_explicit(args->match_count, 1u,
                                          memory_order_relaxed);
    if (args->match_buffer && slot < kGRDMatchBufferSlots) {
      args->match_buffer[slot] = matched;
    }
  }
}