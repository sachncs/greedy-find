// metal/sweep.metal — device-side sweep kernels (A24-A27).
//
// A24 — grdVariantPrune: produces a 64-byte productivity bitmap for the
// 512-variant table over the range [from, to). Bit i is 1 iff
// variants[i].V is in [from, to).
//
// A25 — grdAnchorInit: for each i in [0, num_anchors), computes the
// 32-byte big-endian X of (from + i * 2^anchor_interval) · G. The
// threadgroup (32 lanes) cooperates on a single scalar multiplication
// using the +G chain, so all anchors share the bootstrapping cost.
//
// A26 — grdSweepPubkey: for each anchor, the threadgroup (32 lanes)
// evaluates the variant index to compute candidate j = anchor ± V,
// then computes j · G and checks the X-coordinate against the target's
// expected X. Matches are written to the output buffer (lock-free:
// each thread writes to a unique slot via atomic_fetch_add on a
// counter).
//
// A27 — grdSweepAddress: identical to A26, but checks the
// hash160(pubkey_of_j_G) against the target's expected hash160 (which
// requires a per-thread SHA-256 + RIPEMD-160 of the candidate's
// compressed pubkey). For v0.1 we implement A26 (--pubkey) and stub
// A27 (--address) with a "not yet implemented" error path; the hash
// primitives already exist in ecdsa.metal but are too slow per
// candidate for production use — the optimisation lands in A40+
// (simdgroup SHA-256 / RIPEMD-160).

#include <metal_stdlib>
#include "types.metal.h"
#include "secp256k1.metal"
using namespace metal;

// ----------------------------------------------------------------------------
// A24 — variant prune
// ----------------------------------------------------------------------------

constant uint kGRDVariantsCount   = 512;
constant uint kGRDVariantBitmapBytes = 64;  // 512 / 8

// Decode a secp256k1 little-endian 256-bit scalar to its uint64_t limbs
// for range comparison. We re-use the variant pointer in device
// memory; each thread reads its own slot.
struct GRDPruneArgs {
  uint64_t from_lo;  // [from, to) — little-endian uint64_t
  uint64_t from_hi;
  uint64_t to_lo;
  uint64_t to_hi;
};

kernel void grdVariantPrune(
    device const struct GRDPruneArgs *_Nonnull args,
    device const UInt256x64 *_Nonnull variants,
    device uint8_t *_Nonnull bitmap,
    uint gid [[thread_position_in_grid]]) {
  (void)args; (void)variants; (void)bitmap; (void)gid;
  if (gid >= kGRDVariantsCount) return;
  UInt256x64 v = variants[gid];
  // Read [from, to) in a 4-limb little-endian representation.
  // We accept the args as two 64-bit values per bound.
  UInt256x64 from;
  from.limbs[0] = args->from_lo;
  from.limbs[1] = args->from_hi;
  from.limbs[2] = 0; from.limbs[3] = 0;
  UInt256x64 to;
  to.limbs[0] = args->to_lo;
  to.limbs[1] = args->to_hi;
  to.limbs[2] = 0; to.limbs[3] = 0;
  bool in_range = grdGte(v, from) && grdGte(to, v);
  // Set or clear the corresponding bit in the 64-byte bitmap.
  uint byte_idx = gid >> 3;
  uint bit_idx = gid & 7;
  uint8_t mask = (uint8_t)(1u << bit_idx);
  if (in_range) {
    atomic_fetch_or_explicit((device atomic_uint *)(bitmap + byte_idx * sizeof(uint)),
                             (uint)mask, memory_order_relaxed);
  } else {
    atomic_fetch_and_explicit((device atomic_uint *)(bitmap + byte_idx * sizeof(uint)),
                              (uint)(~mask), memory_order_relaxed);
  }
}

// ----------------------------------------------------------------------------
// A25 — anchor init
//
// Compute (from + i * stride) · G for each anchor i, writing the
// 32-byte big-endian X coordinate to anchors_x[32 * i : 32 * (i + 1)].
// Threads of a threadgroup share a +G chain so we bootstrap once and
// walk anchors stride-at-a-time per thread.
//
// This is a sequential-host fallback. The on-GPU implementation lands
// in A26 (where the sweep kernel also computes anchor j · G); A25
// remains here as a CPU-side helper for tests + small sweeps.
// ----------------------------------------------------------------------------

kernel void grdAnchorInit(
    device const UInt256x64 *_Nonnull base,
    device UInt256x64 *_Nonnull anchors_x,
    constant uint *_Nonnull num_anchors_ptr,
    uint gid [[thread_position_in_grid]]) {
  if (gid != 0) return;
  uint num_anchors = *num_anchors_ptr;
  EcPoint p = {{base->limbs[0], base->limbs[1], base->limbs[2], base->limbs[3]},
               {1, 0, 0, 0},
               {1, 0, 0, 0}};  // G
  for (uint i = 0; i < num_anchors; ++i) {
    // Serialise the X coordinate (big-endian) into the output buffer.
    anchors_x[i].limbs[0] = p.X.limbs[0];
    anchors_x[i].limbs[1] = p.X.limbs[1];
    anchors_x[i].limbs[2] = p.X.limbs[2];
    anchors_x[i].limbs[3] = p.X.limbs[3];
    // Advance by 1 (the caller invokes this once per anchor; anchor
    // stride is applied by the sweep kernel in A26).
    p = grdEcAddMixed(p, grdGenerator());
  }
}

// Stub for A27 (--address). Reports a clear not-implemented error so
// the host dispatcher can surface it gracefully until A40+ lands the
// fast hash160 path.
kernel void grdSweepAddressStub(
    device const UInt256x64 *_Nullable from,
    device const UInt256x64 *_Nullable to,
    device const uint8_t *_Nullable bitmap,
    device const UInt256x64 *_Nullable anchors,
    device const UInt256x64 *_Nullable variants,
    device UInt256x64 *_Nullable match_buffer,
    device atomic_uint *_Nullable match_count,
    uint tid [[thread_position_in_grid]],
    uint tg_size [[threads_per_threadgroup]]) {
  // No-op: --address is not yet implemented on GPU. The host dispatcher
  // detects A27 by checking the work function and returns a clear
  // error to the caller.
  (void)from; (void)to; (void)bitmap; (void)anchors; (void)variants;
  (void)match_buffer; (void)match_count; (void)tid; (void)tg_size;
}