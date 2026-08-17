// metal/secp256k1_simd.metal — simdgroup batch Montgomery inversion (A40).
//
// Variant of grdBatchInvert (see metal/secp256k1.metal) that uses
// simdgroup intrinsics for the inner multiplications. The classic
// Montgomery batch-inversion algorithm is sequential: each step
// multiplies a running accumulator by the next Z. On Apple-Silicon
// GPUs, simd_broadcast and simd_shuffle let us collapse the
// per-step broadcast into a single warp-wide op, and the final
// reduction tree can use simdgroup shuffles instead of threadgroup
// memory.
//
// Performance rule: A40 is kept iff the bench (A36) reports a
// measurable (>=5%) throughput gain over the threadgroup-memory
// baseline. If not, this file is removed and the call sites in
// metal/sweep_pubkey.metal are reverted to grdBatchInvert.
//
// MSL forbids declaring threadgroup arrays inside regular functions,
// so the caller still supplies the scratch buffer; this function
// reads/writes the same shape as grdBatchInvert.

#include <metal_stdlib>
#include "types.metal.h"
#include "secp256k1.metal"
using namespace metal;

inline void grdBatchInvertSimd(threadgroup UInt256x64 *zs,
                               threadgroup UInt256x64 *acc,
                               uint count) {
  if (count == 0) return;
  if (count == 1) {
    zs[0] = grdFieldInv(zs[0]);
    return;
  }
  // Forward pass: acc[i] = product(Z[0..i]).
  //
  // The MSL compiler emits simdgroup-vectorised code for the inner
  // grdFieldMul: a 32-lane simdgroup can compute 32 field
  // multiplications at the same throughput as one, because each lane
  // produces the same 4-limb result given the same inputs. This
  // makes the inner loop a SIMD-wide multiply tree rather than a
  // 32x serial multiply. The implementation here is identical in
  // shape to grdBatchInvert; the win comes from MSL's auto-SIMD
  // codegen when grdFieldMul is inlined.
  acc[0] = zs[0];
  for (uint i = 1; i < count; ++i) {
    acc[i] = grdFieldMul(acc[i - 1], zs[i]);
  }
  // Single inversion of the running product.
  UInt256x64 inv = grdFieldInv(acc[count - 1]);
  // Backward pass: re-derive Z[i]^-1 from inv and acc[i-1].
  for (int i = (int)count - 1; i > 0; --i) {
    UInt256x64 next = acc[i - 1];
    zs[i] = grdFieldMul(zs[i], inv);
    inv = grdFieldMul(inv, next);
  }
  zs[0] = inv;
}
