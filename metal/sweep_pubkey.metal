// metal/sweep_pubkey.metal — A26 sweep kernel for --pubkey mode.
//
// Combined path: host precomputes the anchor table (full EcPoint
// per j), and the kernel does per-lane scalar mul for V·G. The
// V·G precompute path (which would replace the per-lane mul) is
// temporarily disabled in the host — see commit 2b57a0c —
// because secp256k1's tweak_mul aborter fires asynchronously on
// some variant values. Until that follow-up lands, the kernel
// falls back to the slower per-lane path which is at least
// correct.
//
// Per-threadgroup work:
//   1. Load anchor[j_idx] as a full EcPoint.
//   2. Each lane reads V[k] (k = chunk*32 + lid) and computes vG =
//      grdScalarMul(grdGenerator(), V).
//   3. candidate = grdEcAddMixed(anchor, vG).
//   4. Compare X to target; on match, store j + V.

#include <metal_stdlib>
#include "types.metal.h"
#include "secp256k1.metal"
using namespace metal;

constant uint kGRDSweepLanes     = 32;
constant uint kGRDVariantsTotal  = 512;
constant uint kGRDVariantChunks  = kGRDVariantsTotal / kGRDSweepLanes;  // 16

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
    device const UInt256x64 *_Nullable variants,
    uint gid [[thread_position_in_grid]],
    uint lid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]]) {
  if (tg_size != kGRDSweepLanes) return;

  uint j_idx     = gid / kGRDVariantChunks;
  uint chunk_idx = gid % kGRDVariantChunks;
  if (j_idx >= args->num_anchors) return;

  EcPoint anchor = args->anchors[j_idx];

  uint variant_idx = chunk_idx * kGRDSweepLanes + lid;
  UInt256x64 v = variants[variant_idx];

  // Per-lane scalar mul for V·G. Slow but correct.
  EcPoint vG = grdScalarMul(grdGenerator(), v);
  EcPoint candidate = grdEcAddMixed(anchor, vG);

  UInt256x64 target;
  target.limbs[0] = args->target_x->limbs[0];
  target.limbs[1] = args->target_x->limbs[1];
  target.limbs[2] = args->target_x->limbs[2];
  target.limbs[3] = args->target_x->limbs[3];

  if (grdEq(candidate.X, target)) {
    // Mark the match by storing (j_idx * 512 + variant_idx). The
    // host decodes this to recover j + V.
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
