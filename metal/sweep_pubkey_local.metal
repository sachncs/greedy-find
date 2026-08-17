// metal/sweep_pubkey_local.metal — per-threadgroup local match
// buffer (A42).
//
// Variant of grdSweepPubkey that accumulates matches in
// threadgroup memory (one slot per lane) and only flushes to the
// global match buffer once per threadgroup. The flush uses a
// single atomic_fetch_add per threadgroup instead of one per
// match, eliminating the global-memory atomic contention that
// dominates the inner loop at high match rates.
//
// Measured-revert rule: keep iff bench/sweep_bench (run with the
// A42 kernel selected) shows >=5% j/sec gain. If not, this file
// is removed and the call site in host/sweeper.m stays on
// grdSweepPubkey.

#include <metal_stdlib>
#include "types.metal.h"
#include "secp256k1.metal"
using namespace metal;

constant uint kGRDSweepLanesLocal = 32;
constant uint kGRDLocalMatchSlots = 32;  // one slot per lane

struct GRDSweepArgs {
  device const UInt256x64 *_Nullable target_x;
  device const uint8_t *_Nullable bitmap;
  device const UInt256x64 *_Nullable anchors;
  uint num_anchors;
  device UInt256x64 *_Nullable match_buffer;
  device atomic_uint *_Nullable match_count;
  uint from_lo;
  uint from_hi;
  uint to_lo;
  uint to_hi;
};

kernel void grdSweepPubkeyLocal(
    device const struct GRDSweepArgs *_Nonnull args,
    device const UInt256x64 *_Nullable variants,
    uint gid [[thread_position_in_grid]],
    uint lid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]]) {
  if (tg_size != kGRDSweepLanesLocal) return;

  // Threadgroup-local match buffer: one slot per lane, plus a
  // threadgroup-local counter.
  threadgroup UInt256x64 tg_matches[kGRDLocalMatchSlots];
  threadgroup atomic_uint tg_match_count;
  if (lid == 0) atomic_store_explicit(&tg_match_count, 0u,
                                      memory_order_relaxed);
  threadgroup_barrier(mem_flags::mem_threadgroup);

  uint anchor_idx = gid / kGRDSweepLanesLocal;
  if (anchor_idx >= args->num_anchors) return;

  device const UInt256x64 *anchor = args->anchors + anchor_idx;
  EcPoint base;
  base.X = *anchor;
  base.Y = {{1, 0, 0, 0}};
  base.Z = {{1, 0, 0, 0}};

  UInt256x64 target;
  device const UInt256x64 *tx = args->target_x;
  target.limbs[0] = tx->limbs[0];
  target.limbs[1] = tx->limbs[1];
  target.limbs[2] = tx->limbs[2];
  target.limbs[3] = tx->limbs[3];

  UInt256x64 v = variants[lid];
  bool negate_v = (lid & 1u) != 0u;
  UInt256x64 v_signed = v;
  if (negate_v) v_signed = variants[256 + lid];

  EcPoint j_point;
  j_point = grdScalarMul(grdGenerator(), v_signed);
  j_point = grdEcAddMixed(base, j_point);

  // Local match write: append to the threadgroup buffer if the
  // threadgroup still has room. On overflow we drop (the global
  // dispatcher retries with a fresh buffer per A29's recovery
  // rules).
  if (grdEq(j_point.X, target)) {
    UInt256x64 j_val = grdFieldAdd(*anchor, v_signed);
    uint slot = atomic_fetch_add_explicit(&tg_match_count, 1u,
                                          memory_order_relaxed);
    if (slot < kGRDLocalMatchSlots) {
      tg_matches[slot] = j_val;
    }
  }

  // Synchronise so all lanes see the final tg_match_count.
  threadgroup_barrier(mem_flags::mem_threadgroup);

  // Single flush per threadgroup: the first lane reserves a contiguous
  // global slot, then lanes 0..N-1 each copy their local match.
  if (lid == 0) {
    uint n = atomic_load_explicit(&tg_match_count, memory_order_relaxed);
    if (n > kGRDLocalMatchSlots) n = kGRDLocalMatchSlots;
    uint base = atomic_fetch_add_explicit(args->match_count, n,
                                          memory_order_relaxed);
    for (uint i = 0; i < n; ++i) {
      if (args->match_buffer) args->match_buffer[base + i] = tg_matches[i];
    }
  }
}
