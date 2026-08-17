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
// we delegate to `grdFieldMul` here; future optimisation may rewrite
// this with the symmetric form if benchmarks justify.
// ----------------------------------------------------------------------------

inline UInt256x64 grdFieldSqr(UInt256x64 a) {
  return grdFieldMul(a, a);
}

// ----------------------------------------------------------------------------
// Modular inverse via Fermat's little theorem
//
// For prime p, a^(p-2) mod p = a^(-1) mod p (when a != 0). The
// exponentiation uses square-and-multiply with the standard binary
// representation of (p-2) = 2^256 - 2^32 - 979 (i.e. p - 3).
//
// Not constant-time; the sweep context does not require it.
// ----------------------------------------------------------------------------

/**
 * Returns a^(-1) mod p (or 0 if a == 0). Uses Fermat's little theorem:
 * a^(p-2) mod p.
 */
inline UInt256x64 grdFieldInv(UInt256x64 a) {
  // Exponent = p - 2 =
  //   0xFFFFFFFFFFFFFFFF FFFFFFFFFFFFFFFF FFFFFFFFFFFFFFFF FFFFFFFEFFFFFC2D
  UInt256x64 result = {{1ul, 0ul, 0ul, 0ul}};
  UInt256x64 base = a;
  for (uint i = 0; i < 256; ++i) {
    constexpr ulong kExpLo = 0xFFFFFFFEFFFFFC2Dul;
    constexpr ulong kExp1 = 0xFFFFFFFFFFFFFFFFul;
    constexpr ulong kExp2 = 0xFFFFFFFFFFFFFFFFul;
    constexpr ulong kExp3 = 0xFFFFFFFFFFFFFFFFul;
    uint bit;
    if (i < 64) bit = (kExpLo >> i) & 1u;
    else if (i < 128) bit = (kExp1 >> (i - 64)) & 1u;
    else if (i < 192) bit = (kExp2 >> (i - 128)) & 1u;
    else bit = (kExp3 >> (i - 192)) & 1u;
    if (bit) result = grdFieldMul(result, base);
    if (i < 255) base = grdFieldSqr(base);
  }
  return result;
}

// ----------------------------------------------------------------------------
// Elliptic curve point arithmetic
//
// Jacobian projective coordinates: affine = (X / Z^2, Y / Z^3). For
// secp256k1 the curve is y^2 = x^3 + 7 (a = 0, b = 7).
//
// The doubling / addition formulas are the standard ones from
// "Software Implementation of Elliptic Curve Cryptography" (Hankerson
// et al.) and the Wikipedia write-ups. All formulas are derived for
// a = 0 which simplifies several terms.
// ----------------------------------------------------------------------------

/** Returns `2 * P` in Jacobian projective coordinates. */
inline EcPoint grdEcDouble(EcPoint p) {
  if (grdIsZero(p.Z)) return p;

  UInt256x64 A = grdFieldSqr(p.X);
  UInt256x64 B = grdFieldSqr(p.Y);
  UInt256x64 C = grdFieldSqr(B);

  // D = 2 * ((X + B)^2 - A - C)
  UInt256x64 t = grdFieldAdd(p.X, B);
  t = grdFieldSqr(t);
  t = grdFieldSub(t, A);
  t = grdFieldSub(t, C);
  UInt256x64 D = grdFieldAdd(t, t);

  // E = 3 * A  (since a = 0)
  UInt256x64 E = grdFieldAdd(grdFieldAdd(A, A), A);

  EcPoint r;
  r.X = grdFieldSub(grdFieldSqr(E), grdFieldAdd(D, D));
  r.Y = grdFieldSub(D, r.X);
  r.Y = grdFieldMul(E, r.Y);
  r.Y = grdFieldSub(r.Y, grdFieldAdd(grdFieldAdd(grdFieldAdd(C, C),
                                                   grdFieldAdd(C, C)),
                                       grdFieldAdd(grdFieldAdd(C, C),
                                                   grdFieldAdd(C, C))));
  r.Z = grdFieldMul(grdFieldAdd(p.Y, p.Y), p.Z);
  return r;
}

/** Returns `P + Q` in Jacobian projective coordinates (full add). */
inline EcPoint grdEcAdd(EcPoint p, EcPoint q) {
  if (grdIsZero(p.Z)) return q;
  if (grdIsZero(q.Z)) return p;

  UInt256x64 Z1Z1 = grdFieldSqr(p.Z);
  UInt256x64 Z2Z2 = grdFieldSqr(q.Z);
  UInt256x64 U1 = grdFieldMul(p.X, Z2Z2);
  UInt256x64 U2 = grdFieldMul(q.X, Z1Z1);
  UInt256x64 S1 = grdFieldMul(p.Y, grdFieldMul(Z2Z2, q.Z));
  UInt256x64 S2 = grdFieldMul(q.Y, grdFieldMul(Z1Z1, p.Z));
  UInt256x64 H = grdFieldSub(U2, U1);
  UInt256x64 I = grdFieldAdd(grdFieldAdd(H, H), grdFieldSqr(H));
  UInt256x64 J = grdFieldMul(H, I);
  UInt256x64 rr = grdFieldSub(S2, S1);  // r = S2 - S1
  UInt256x64 V = grdFieldMul(U1, grdFieldSqr(H));
  UInt256x64 r2 = grdFieldSub(grdFieldSub(grdFieldSqr(rr), J),
                              grdFieldAdd(V, V));

  EcPoint r;
  r.X = grdFieldMul(I, r2);
  r.Y = grdFieldSub(grdFieldMul(rr, grdFieldSub(V, r2)),
                      grdFieldMul(S1, J));
  r.Z = grdFieldMul(grdFieldMul(p.Z, q.Z), H);
  return r;
}

/** Returns `P + Q` where Q is affine (Z = 1). Cheaper than full add. */
inline EcPoint grdEcAddMixed(EcPoint p, EcPoint q) {
  if (grdIsZero(p.Z)) return q;
  if (grdIsZero(q.Z)) return p;

  UInt256x64 Z1Z1 = grdFieldSqr(p.Z);
  UInt256x64 U2 = grdFieldMul(q.X, Z1Z1);
  UInt256x64 S2 = grdFieldMul(q.Y, grdFieldMul(Z1Z1, p.Z));
  UInt256x64 H = grdFieldSub(U2, p.X);
  UInt256x64 I = grdFieldAdd(grdFieldAdd(H, H), grdFieldSqr(H));
  UInt256x64 J = grdFieldMul(H, I);
  UInt256x64 r2 = grdFieldSub(grdFieldSub(grdFieldSqr(S2), J),
                              grdFieldAdd(grdFieldAdd(p.X, p.X), p.X));

  EcPoint r;
  r.X = grdFieldMul(I, r2);
  r.Y = grdFieldSub(grdFieldMul(grdFieldAdd(S2, S2), J),
                      grdFieldMul(H, r2));
  r.Z = grdFieldAdd(grdFieldAdd(p.Z, p.Z),
                      grdFieldMul(grdFieldAdd(H, H), p.Z));
  return r;
}

/** Returns `-P` in Jacobian projective coordinates. */
inline EcPoint grdEcNeg(EcPoint p) {
  EcPoint r;
  r.X = p.X;
  r.Y = grdFieldSub(grdPrimeP(), p.Y);  // -Y mod p = p - Y
  r.Z = p.Z;
  return r;
}

// ----------------------------------------------------------------------------
// Montgomery batch inversion
//
// Given N projective points, computes the inverses of their Z
// coordinates using a single field inversion. Algorithm:
//
//   1. accumulate[i+1] = Z[i+1] * accumulate[i]
//   2. inv = (accumulate[N-1])^-1
//   3. For i = N-1 down to 0:
//        next = accumulate[i-1]   (or 1 if i == 0)
//        result[i] = accumulate[i] * inv   (= Z[i]^-1)
//        inv = next * inv
//
// Caller passes both zs (in/out) and acc (scratch, both threadgroup).
// MSL forbids declaring threadgroup arrays inside regular functions, so
// the scratch buffer is provided by the caller kernel.
// ----------------------------------------------------------------------------

inline void grdBatchInvert(threadgroup UInt256x64 *zs,
                           threadgroup UInt256x64 *acc,
                           uint count) {
  if (count == 0) return;
  if (count == 1) {
    zs[0] = grdFieldInv(zs[0]);
    return;
  }
  acc[0] = zs[0];
  for (uint i = 1; i < count; ++i) {
    acc[i] = grdFieldMul(acc[i - 1], zs[i]);
  }
  UInt256x64 inv = grdFieldInv(acc[count - 1]);
  for (int i = (int)count - 1; i > 0; --i) {
    UInt256x64 next = acc[i - 1];
    zs[i] = grdFieldMul(zs[i], inv);
    inv = grdFieldMul(inv, next);
  }
  zs[0] = inv;
}

// ----------------------------------------------------------------------------
// Scalar multiplication
//
// Binary double-and-add. For a scalar < 2^256 we walk the bits MSB to
// LSB and double at each step, adding the base whenever the bit is set.
// Not constant-time; for the sweep context (j is public) this is fine.
// ----------------------------------------------------------------------------

inline EcPoint grdScalarMul(EcPoint p, EcScalar k) {
  EcPoint result = grdIdentity();
  bool found_one = false;
  for (int i = 255; i >= 0; --i) {
    if (found_one) result = grdEcDouble(result);
    uint bit;
    if (i < 64) bit = (k.limbs[0] >> i) & 1u;
    else if (i < 128) bit = (k.limbs[1] >> (i - 64)) & 1u;
    else if (i < 192) bit = (k.limbs[2] >> (i - 128)) & 1u;
    else bit = (k.limbs[3] >> (i - 192)) & 1u;
    if (bit) {
      if (found_one) result = grdEcAdd(result, p);
      else {
        result = p;
        found_one = true;
      }
    }
  }
  return result;
}

inline EcPoint grdScalarMulG(EcScalar k) {
  return grdScalarMul(grdGenerator(), k);
}

// ----------------------------------------------------------------------------
// Reduction mod n (curve order)
//
// For the sweep context, j fits in u128. We simply subtract n until
// the result is < n. Since n is 256 bits and j <= 2^71, at most one
// subtraction is needed.
// ----------------------------------------------------------------------------

inline UInt256x64 grdReduceModN(UInt256x64 a) {
  UInt256x64 n = grdOrderN();
  while (grdGte(a, n)) {
    uint64_t borrow = 0u;
    a.limbs[0] = grdSubc(a.limbs[0], n.limbs[0], 0u, borrow);
    a.limbs[1] = grdSubc(a.limbs[1], n.limbs[1], borrow, borrow);
    a.limbs[2] = grdSubc(a.limbs[2], n.limbs[2], borrow, borrow);
    a.limbs[3] = grdSubc(a.limbs[3], n.limbs[3], borrow, borrow);
  }
  return a;
}