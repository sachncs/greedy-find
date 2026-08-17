// metal/prefix_index.metal — 8-byte prefix index (A43).
//
// Precomputed 64-bit → candidate-list index for the X-coord space.
// The first pass of the sweep compares only the leading 8 bytes of
// the candidate's X coordinate; on a miss the full 32-byte compare
// is skipped. The full compare still happens on a hit (to rule
// out collisions), but the win is that 2^64-key space is large
// enough that the miss rate is overwhelming in practice.
//
// The host builds the index from the variant table on setup and
// uploads it as a small buffer. The kernel takes the index and a
// target-prefix as inputs.
//
// Measured-revert rule: keep iff bench/sweep_bench (run with the
// A43 index attached) shows >=5% j/sec gain. If not, this file is
// removed and host/sweeper.m stays on the unindexed sweep.

#include <metal_stdlib>
#include "types.metal.h"
#include "secp256k1.metal"
using namespace metal;

// Sweep args: mirrored from metal/sweep_pubkey.metal so this file
// compiles standalone. Kept in lock-step with the host.
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

// One prefix-bucket entry. Each bucket holds up to kBucketSize
// variant indices. The host guarantees this is enough for any
// 8-byte prefix; on overflow the host re-hashes or extends the
// bucket.
constant uint kBucketSize = 16;
struct GRDPrefixBucket {
  uint count;
  uint variants[kBucketSize];
};

inline uint64_t grdPrefixOf(UInt256x64 x) {
  // First 8 bytes of big-endian X = top 64 bits = limbs[3].
  return x.limbs[3];
}

kernel void grdBuildPrefixIndex(
    device const UInt256x64 *_Nonnull variants,
    device GRDPrefixBucket *_Nonnull index,
    constant uint &num_variants,
    constant uint &num_buckets,
    uint gid [[thread_position_in_grid]]) {
  if (gid >= num_variants) return;
  UInt256x64 v = variants[gid];
  uint64_t prefix = grdPrefixOf(v);
  uint bucket = (uint)(prefix % (uint64_t)num_buckets);
  uint slot = index[bucket].count;
  if (slot < kBucketSize) {
    index[bucket].variants[slot] = gid;
  }
  index[bucket].count = (slot < kBucketSize) ? (slot + 1u) : slot;
}

kernel void grdSweepPubkeyPrefix(
    device const struct GRDSweepArgs *_Nonnull args,
    device const UInt256x64 *_Nullable variants,
    device const GRDPrefixBucket *_Nonnull index,
    constant uint &num_buckets,
    uint gid [[thread_position_in_grid]],
    uint lid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]]) {
  if (tg_size != 32) return;

  uint anchor_idx = gid / 32;
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
  uint64_t target_prefix = grdPrefixOf(target);

  uint bucket_id = lid;
  if (bucket_id < num_buckets) {
    device const GRDPrefixBucket *b = &index[bucket_id];
    if (b->count > 0) {
      for (uint i = 0; i < b->count; ++i) {
        uint v_idx = b->variants[i];
        if (v_idx >= 512) continue;
        UInt256x64 v = variants[v_idx];
        bool negate = (v_idx & 1u) != 0u;
        if (negate) v = variants[256 + v_idx];
        EcPoint jp = grdScalarMul(grdGenerator(), v);
        jp = grdEcAddMixed(base, jp);
        if (grdPrefixOf(jp.X) != target_prefix) continue;
        if (grdEq(jp.X, target)) {
          UInt256x64 j_val = grdFieldAdd(*anchor, v);
          uint slot = atomic_fetch_add_explicit(args->match_count, 1u,
                                                memory_order_relaxed);
          if (args->match_buffer && slot < 0x100000) {
            args->match_buffer[slot] = j_val;
          }
        }
      }
    }
  }
}
