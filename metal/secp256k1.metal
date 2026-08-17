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
 * Returns the lower 64 bits of `a + b + carry_in` and writes the carry
 * (0 or 1) to `carry_out`. Constant-time at the limb level but the
 * overall function is NOT constant-time — used only in the sweep context.
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
 * Returns the lower 64 bits of `a - b - borrow_in` and writes the
 * borrow (0 or 1) to `borrow_out`.
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

// ----------------------------------------------------------------------------
// Modular add / sub (mod p)
// ----------------------------------------------------------------------------

inline UInt256x64 grdFieldAdd(UInt256x64 a, UInt256x64 b) {
  UInt256x64 sum;
  uint64_t carry = 0u;
  sum.limbs[0] = grdAddc(a.limbs[0], b.limbs[0], 0u, carry);
  sum.limbs[1] = grdAddc(a.limbs[1], b.limbs[1], carry, carry);
  sum.limbs[2] = grdAddc(a.limbs[2], b.limbs[2], carry, carry);
  sum.limbs[3] = grdAddc(a.limbs[3], b.limbs[3], carry, carry);

  bool overflow = (carry != 0u);
  if (!overflow) {
    overflow = (sum.limbs[3] > grdPrimeP().limbs[3])
               || ((sum.limbs[3] == grdPrimeP().limbs[3])
                   && ((sum.limbs[2] > grdPrimeP().limbs[2])
                       || ((sum.limbs[2] == grdPrimeP().limbs[2])
                           && ((sum.limbs[1] > grdPrimeP().limbs[1])
                               || ((sum.limbs[1] == grdPrimeP().limbs[1])
                                   && (sum.limbs[0]
                                       >= grdPrimeP().limbs[0]))))));
  }
  if (overflow) {
    UInt256x64 p = grdPrimeP();
    uint64_t borrow = 0u;
    sum.limbs[0] = grdSubc(sum.limbs[0], p.limbs[0], 0u, borrow);
    sum.limbs[1] = grdSubc(sum.limbs[1], p.limbs[1], borrow, borrow);
    sum.limbs[2] = grdSubc(sum.limbs[2], p.limbs[2], borrow, borrow);
    sum.limbs[3] = grdSubc(sum.limbs[3], p.limbs[3], borrow, borrow);
  }
  return sum;
}

inline UInt256x64 grdFieldSub(UInt256x64 a, UInt256x64 b) {
  UInt256x64 diff;
  uint64_t borrow = 0u;
  diff.limbs[0] = grdSubc(a.limbs[0], b.limbs[0], 0u, borrow);
  diff.limbs[1] = grdSubc(a.limbs[1], b.limbs[1], borrow, borrow);
  diff.limbs[2] = grdSubc(a.limbs[2], b.limbs[2], borrow, borrow);
  diff.limbs[3] = grdSubc(a.limbs[3], b.limbs[3], borrow, borrow);

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
// Comparison / equality
// ----------------------------------------------------------------------------

inline bool grdEq(UInt256x64 a, UInt256x64 b) {
  return a.limbs[0] == b.limbs[0] && a.limbs[1] == b.limbs[1]
         && a.limbs[2] == b.limbs[2] && a.limbs[3] == b.limbs[3];
}

inline bool grdIsZero(UInt256x64 a) {
  return a.limbs[0] == 0u && a.limbs[1] == 0u && a.limbs[2] == 0u
         && a.limbs[3] == 0u;
}

inline bool grdGte(UInt256x64 a, UInt256x64 b) {
  if (a.limbs[3] != b.limbs[3]) return a.limbs[3] > b.limbs[3];
  if (a.limbs[2] != b.limbs[2]) return a.limbs[2] > b.limbs[2];
  if (a.limbs[1] != b.limbs[1]) return a.limbs[1] > b.limbs[1];
  return a.limbs[0] >= b.limbs[0];
}

// ----------------------------------------------------------------------------
// Field multiplication (mod p)
//
// Algorithm:
//   1. Compute 4×4 schoolbook product → 8-limb (512-bit) result.
//   2. Apply secp256k1 fast reduction: since p = 2^256 - (2^32 + 977),
//      we have 2^256 ≡ 2^32 + 977 (mod p).
//   3. Iteratively replace the high half (R_high) by R_high * c, where
//      c = 2^32 + 977 = 4294968273, until the value fits in 256 bits.
//   4. Conditional subtract p if needed.
// ----------------------------------------------------------------------------

/** Returns `a * b (mod p)`. */
inline UInt256x64 grdFieldMul(UInt256x64 a, UInt256x64 b) {
  uint64_t r[8] = {0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u};

  // 4×4 schoolbook — 16 partial products.
  for (uint64_t i = 0; i < 4; ++i) {
    uint64_t carry = 0u;
    for (uint64_t j = 0; j < 4; ++j) {
      unsigned __int128 prod =
          (unsigned __int128)a.limbs[i] * (unsigned __int128)b.limbs[j];
      uint64_t lo = (uint64_t)prod;
      uint64_t hi = (uint64_t)(prod >> 64);
      uint64_t s = r[i + j] + lo;
      uint64_t c1 = (s < r[i + j]) ? 1u : 0u;
      uint64_t s2 = s + carry;
      uint64_t c2 = (s2 < s) ? 1u : 0u;
      r[i + j] = s2;
      carry = hi + c1 + c2;
    }
    r[i + 4] += carry;
  }

  // Iterative reduction. Each iteration: r_low += r_high * c, where
// c = 2^32 + 977. Repeated until r fits in 256 bits.
  constexpr uint64_t kC = (1ull << 32) + 977ull;

  while (r[4] != 0u || r[5] != 0u || r[6] != 0u || r[7] != 0u) {
    uint64_t new_r[5] = {r[0], r[1], r[2], r[3], 0u};
    uint64_t carry = 0u;
    for (int i = 0; i < 4; ++i) {
      unsigned __int128 prod =
          (unsigned __int128)r[4 + i] * (unsigned __int128)kC;
      uint64_t prod_lo = (uint64_t)prod;
      uint64_t prod_hi = (uint64_t)(prod >> 64);
      unsigned __int128 sum = (unsigned __int128)new_r[i]
                              + (unsigned __int128)prod_lo
                              + (unsigned __int128)carry;
      new_r[i] = (uint64_t)sum;
      carry = (uint64_t)(sum >> 64) + prod_hi;
    }
    new_r[4] = carry;
    r[0] = new_r[0];
    r[1] = new_r[1];
    r[2] = new_r[2];
    r[3] = new_r[3];
    r[4] = new_r[4];
    r[5] = 0u;
    r[6] = 0u;
    r[7] = 0u;
  }

  // Conditional subtract p (in case value is still >= p).
  UInt256x64 result = {{r[0], r[1], r[2], r[3]}};
  UInt256x64 p = grdPrimeP();
  while (grdGte(result, p)) {
    uint64_t borrow = 0u;
    result.limbs[0] = grdSubc(result.limbs[0], p.limbs[0], 0u, borrow);
    result.limbs[1] = grdSubc(result.limbs[1], p.limbs[1], borrow, borrow);
    result.limbs[2] = grdSubc(result.limbs[2], p.limbs[2], borrow, borrow);
    result.limbs[3] = grdSubc(result.limbs[3], p.limbs[3], borrow, borrow);
  }

  return result;
}

// ----------------------------------------------------------------------------
// Field squaring (mod p)
//
// Specialised form of `grdFieldMul(a, a)` — saves ~half the partial
// products via symmetry (a*b*j == a*j*b for i != j). For simplicity
// we delegate to `grdFieldMul` here; A9 may rewrite this with the
// symmetric form if benchmarks justify.
// ----------------------------------------------------------------------------

inline UInt256x64 grdFieldSqr(UInt256x64 a) {
  return grdFieldMul(a, a);
}