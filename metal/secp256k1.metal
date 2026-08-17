// metal/secp256k1.metal — secp256k1 prime-field arithmetic.
//
// Field element representation: UInt256x64 (little-endian 4×64-bit limbs).
// Arithmetic is implemented limb-by-limb in scalar code; the GPU compiler
// unrolls the tight loops. Every public function returns a fresh
// UInt256x64 (no aliasing required by callers) to keep the IR simple and
// match the conventions of `find/src/ecc.rs`.

#include <metal_stdlib>
#include "types.metal.h"
using namespace metal;

// ----------------------------------------------------------------------------
// Low-level limb arithmetic helpers
// ----------------------------------------------------------------------------

/**
 * Returns (sum, carry) of `a + b + carry_in`. The result limb is the
 * lower 64 bits of the unsigned sum; carry is 0 or 1.
 */
inline uint64_t grdAddc(uint64_t a, uint64_t b, uint64_t carry_in,
                        thread uint64_t &carry_out) {
  uint64_t s = a + b;
  uint64_t c1 = (s < a) ? 1u : 0u;
  s += carry_in;
  uint64_t c2 = (s < carry_in) ? 1u : 0u;
  carry_out = c1 | c2;
  return s;
}

/**
 * Returns (diff, borrow) of `a - b - borrow_in`. The result is the
 * lower 64 bits of (a - b - borrow_in); borrow is 0 or 1.
 */
inline uint64_t grdSubc(uint64_t a, uint64_t b, uint64_t borrow_in,
                        thread uint64_t &borrow_out) {
  uint64_t d = a - b;
  uint64_t b1 = (d > a) ? 1u : 0u;
  uint64_t d2 = d - borrow_in;
  uint64_t b2 = (d2 > d) ? 1u : 0u;
  borrow_out = b1 | b2;
  return d2;
}

/**
 * 64-bit unsigned multiply returning the high half of the 128-bit product.
 * Uses the long-multiplication pattern that maps well to MSL's
 * `metal::mulhi` intrinsic where available; falls back to plain math
 * otherwise. Inputs are uint64_t; the high 64 bits are returned as
 * `(a * b) >> 64`.
 */
inline uint64_t grdMulhi(uint64_t a, uint64_t b) {
  return metal::mulhi(a, b);
}

// ----------------------------------------------------------------------------
// Modular add / sub (mod p)
// ----------------------------------------------------------------------------

/**
 * Returns `a + b (mod p)` using two-limb-add reduction. The result is
 * always in [0, p). This is constant-time in the operands (no branches
 * on secret data) at the limb level, but overall the function is NOT
 * constant-time; it is appropriate only for the sweep use case.
 */
inline UInt256x64 grdFieldAdd(UInt256x64 a, UInt256x64 b) {
  UInt256x64 sum;
  uint64_t carry = 0u;
  sum.limbs[0] = grdAddc(a.limbs[0], b.limbs[0], 0u, carry);
  sum.limbs[1] = grdAddc(a.limbs[1], b.limbs[1], carry, carry);
  sum.limbs[2] = grdAddc(a.limbs[2], b.limbs[2], carry, carry);
  sum.limbs[3] = grdAddc(a.limbs[3], b.limbs[3], carry, carry);

  // If carry out OR sum >= p, subtract p. The conditional subtract is
  // safe because we only check the carry and the most-significant limb
  // comparison, both of which are public structural values here.
  UInt256x64 p = grdPrimeP();
  bool overflow = (carry != 0u);
  if (!overflow) {
    overflow = (sum.limbs[3] > p.limbs[3])
               || ((sum.limbs[3] == p.limbs[3])
                   && ((sum.limbs[2] > p.limbs[2])
                       || ((sum.limbs[2] == p.limbs[2])
                           && ((sum.limbs[1] > p.limbs[1])
                               || ((sum.limbs[1] == p.limbs[1])
                                   && (sum.limbs[0] >= p.limbs[0]))))));
  }
  if (overflow) {
    uint64_t borrow = 0u;
    sum.limbs[0] = grdSubc(sum.limbs[0], p.limbs[0], 0u, borrow);
    sum.limbs[1] = grdSubc(sum.limbs[1], p.limbs[1], borrow, borrow);
    sum.limbs[2] = grdSubc(sum.limbs[2], p.limbs[2], borrow, borrow);
    sum.limbs[3] = grdSubc(sum.limbs[3], p.limbs[3], borrow, borrow);
  }
  return sum;
}

/**
 * Returns `a - b (mod p)`. Adds p if necessary so the result lies in
 * [0, p).
 */
inline UInt256x64 grdFieldSub(UInt256x64 a, UInt256x64 b) {
  UInt256x64 diff;
  uint64_t borrow = 0u;
  diff.limbs[0] = grdSubc(a.limbs[0], b.limbs[0], 0u, borrow);
  diff.limbs[1] = grdSubc(a.limbs[1], b.limbs[1], borrow, borrow);
  diff.limbs[2] = grdSubc(a.limbs[2], b.limbs[2], borrow, borrow);
  diff.limbs[3] = grdSubc(a.limbs[3], b.limbs[3], borrow, borrow);

  // If borrow, add p to bring the result back into [0, p).
  if (borrow != 0u) {
    UInt256x64 p = grdPrimeP();
    uint64_t carry = 0u;
    diff.limbs[0] = grdAddc(diff.limbs[0], p.limbs[0], 0u, carry);
    diff.limbs[1] = grdAddc(diff.limbs[1], p.limbs[1], carry, carry);
    diff.limbs[2] = grdAddc(diff.limbs[2], p.limbs[2], carry, carry);
    diff.limbs[3] = grdAddc(diff.limbs[3], p.limbs[3], carry, carry);
  }
  return diff;
}

// ----------------------------------------------------------------------------
// Equality / comparison
// ----------------------------------------------------------------------------

/** Returns true iff `a == b`. */
inline bool grdEq(UInt256x64 a, UInt256x64 b) {
  return a.limbs[0] == b.limbs[0] && a.limbs[1] == b.limbs[1]
         && a.limbs[2] == b.limbs[2] && a.limbs[3] == b.limbs[3];
}

/** Returns true iff `a == 0`. */
inline bool grdIsZero(UInt256x64 a) {
  return a.limbs[0] == 0u && a.limbs[1] == 0u && a.limbs[2] == 0u
         && a.limbs[3] == 0u;
}

/** Returns true iff `a >= b` (lexicographic on limbs, little-endian). */
inline bool grdGte(UInt256x64 a, UInt256x64 b) {
  if (a.limbs[3] != b.limbs[3]) return a.limbs[3] > b.limbs[3];
  if (a.limbs[2] != b.limbs[2]) return a.limbs[2] > b.limbs[2];
  if (a.limbs[1] != b.limbs[1]) return a.limbs[1] > b.limbs[1];
  return a.limbs[0] >= b.limbs[0];
}