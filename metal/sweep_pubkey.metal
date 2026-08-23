// metal/sweep_pubkey.metal — A26 sweep kernel for --pubkey mode.
//
// Path C1: per-threadgroup scalar multiplication from scratch, no
// anchor-table lookup. Each threadgroup is responsible for ONE
// candidate j (where j = from + j_idx), and the 32 lanes within the
// threadgroup test 32 distinct variants in parallel. To cover the full
// 512-variant table, the host dispatches 16 threadgroups per j
// (chunk_idx = 0..15); chunk c uses variants[c*32 .. (c+1)*32).
//
// Per-threadgroup cost: one grdScalarMulG(j) (~256 EC doublings +
// ~128 EC adds) plus 32 × grdScalarMul(V) + 32 × grdEcAddMixed. The
// per-threadgroup scalar mul dominates; production deployments should
// follow up with path C2 (full-point anchor table + +G chain), which
// amortises the bootstrap across the threadgroup.
//
// The host packs gid so:
//   j_idx     = gid / 16         (0 ≤ j_idx < num_anchors)
//   chunk_idx = gid % 16         (0 ≤ chunk_idx < 16)
//
// and dispatches num_anchors × 16 threadgroups of 32 lanes each.
// All threadgroups share the same target_x, bitmap, and variant table.
//
// Reliability notes:
//   - 32 lanes per threadgroup; each lane tests one variant per chunk.
//   - 16 chunks × 32 variants = 512 variants per j (the full table).
//   - Match recovery: stored j_val = j + V (the exact scalar tested).
//     The caller derives d = j + V or d = j − V mod n.
//   - 32-bit match counter; if more than 2^32 matches occur the host
//     retries with a fresh buffer.
//   - No secret-dependent branches; the variant loop is uniform across
//     lanes within a threadgroup.

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
//   offset 16: device const UInt256x64* anchors   (C2 follow-up; C1 ignores)
//   offset 24: uint num_anchors
//   offset 32: device UInt256x64*        match_buffer
//   offset 40: device atomic_uint*       match_count
//   offset 48: uint from_limbs[4]        (u128 little-endian)
//   offset 64: uint to_limbs[4]          (u128 little-endian)
// total: 80 bytes
struct GRDSweepArgs {
  device const UInt256x64 *_Nullable target_x;
  device const uint8_t     *_Nullable bitmap;
  device const UInt256x64 *_Nullable anchors;
  uint                            num_anchors;
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

  // Decompose gid into (j_idx, chunk_idx). 16 threadgroups per j.
  uint j_idx     = gid / kGRDVariantChunks;
  uint chunk_idx = gid % kGRDVariantChunks;
  if (j_idx >= args->num_anchors) return;

  // Reconstruct j = from + j_idx. For v0.1 we use the lo limb only
  // (the host caps per-slice j-count at 2^20 so j_idx is a small u32).
  // The u128 hi limb decode is wired up here so the C2 follow-up does
  // not have to touch this kernel again.
  UInt256x64 j_val;
  j_val.limbs[0] = ((uint64_t)args->from_limbs[1] << 32) |
                    (uint64_t)args->from_limbs[0];
  j_val.limbs[1] = ((uint64_t)args->from_limbs[3] << 32) |
                    (uint64_t)args->from_limbs[2];
  j_val.limbs[2] = 0;
  j_val.limbs[3] = 0;
  j_val.limbs[0] += (uint64_t)j_idx;  // small u32 add, no carry past lo

  // Compute j·G once per threadgroup.
  EcPoint j_point;
  if (j_val.limbs[0] == 0 && j_val.limbs[1] == 0) {
    j_point = grdIdentity();
  } else {
    j_point = grdScalarMulG(j_val);
  }

  // Each lane tests one variant from the chunk.
  uint variant_idx = chunk_idx * kGRDSweepLanes + lid;
  UInt256x64 v = variants[variant_idx];

  // candidate = (j + V) · G = j·G + V·G.
  EcPoint vG = grdScalarMul(grdGenerator(), v);
  EcPoint candidate = grdEcAddMixed(j_point, vG);

  // Compare X to target.
  UInt256x64 target;
  target.limbs[0] = args->target_x->limbs[0];
  target.limbs[1] = args->target_x->limbs[1];
  target.limbs[2] = args->target_x->limbs[2];
  target.limbs[3] = args->target_x->limbs[3];

  if (grdEq(candidate.X, target)) {
    // Store the candidate scalar j + V. The host's recovery formula
    // is d = j + V or d = j − V (mod n), per plan.md §1.
    UInt256x64 matched = grdFieldAdd(j_val, v);
    uint slot = atomic_fetch_add_explicit(args->match_count, 1u,
                                          memory_order_relaxed);
    if (args->match_buffer && slot < 0x100000) {
      args->match_buffer[slot] = matched;
    }
  }
}
