// host/ecc.c — host-side reference implementation of secp256k1
// arithmetic and u128 helpers.
//
// Two purposes:
//   1. Provide host-side C implementations of field/point ops so KATs
//      can run on the CPU without a Metal device.
//   2. Provide u128 helpers used by the host CLI and config code.
//
// The host implementation mirrors `metal/secp256k1.metal` limb-for-limb
// so differential testing against the GPU kernel is straightforward.

#include "ecc.h"

#include <stdio.h>
#include <string.h>

// ----------------------------------------------------------------------------
// secp256k1 prime and order as host UInt256x64
// ----------------------------------------------------------------------------

const GRDUInt256x64 GRDPrimeP = {{
    0xFFFFFFFEFFFFFC2Full, 0xFFFFFFFFFFFFFFFFull, 0xFFFFFFFFFFFFFFFFull,
    0xFFFFFFFFFFFFFFFFull,
}};

const GRDUInt256x64 GRDOrderN = {{
    0xBFD25E8CD0364141ull, 0xBAAEDCE6AF48A03Bull, 0xFFFFFFFFFFFFFFFEull,
    0xFFFFFFFFFFFFFFFFull,
}};

// ----------------------------------------------------------------------------
// u128 helpers (used by CLI parsing)
// ----------------------------------------------------------------------------

void GRDU128Add(GRDUInt128 *out, GRDUInt128 a, GRDUInt128 b) {
  unsigned __int128 sum = (unsigned __int128)a.lo + (unsigned __int128)b.lo;
  out->lo = (uint64_t)sum;
  out->hi = a.hi + b.hi + (uint64_t)(sum >> 64);
}

void GRDU128Sub(GRDUInt128 *out, GRDUInt128 a, GRDUInt128 b) {
  unsigned __int128 diff = (unsigned __int128)a.lo - (unsigned __int128)b.lo;
  out->lo = (uint64_t)diff;
  out->hi = a.hi - b.hi - (uint64_t)(diff > (unsigned __int128)a.lo);
}

int GRDU128Cmp(GRDUInt128 a, GRDUInt128 b) {
  if (a.hi != b.hi) return (a.hi < b.hi) ? -1 : 1;
  if (a.lo != b.lo) return (a.lo < b.lo) ? -1 : 1;
  return 0;
}

bool GRDU128IsZero(GRDUInt128 a) { return a.lo == 0 && a.hi == 0; }

GRDUInt128 GRDU128FromU64(uint64_t v) { return (GRDUInt128){.lo = v, .hi = 0}; }

// ----------------------------------------------------------------------------
// Decimal parsing / formatting
// ----------------------------------------------------------------------------

const char *GRDU128ParseDecimal(GRDUInt128 *out, const char *s) {
  if (!s || !*s) return "empty string";
  GRDUInt128 acc = {0, 0};
  for (const char *p = s; *p; ++p) {
    if (*p < '0' || *p > '9') return "non-decimal character";
    uint8_t digit = (uint8_t)(*p - '0');
    unsigned __int128 mul = (unsigned __int128)acc.lo * 10ull;
    GRDUInt128 tmp = {.lo = (uint64_t)mul,
                      .hi = acc.hi * 10ull + (uint64_t)(mul >> 64)};
    GRDUInt128 incremented;
    GRDU128Add(&incremented, tmp, (GRDUInt128){.lo = digit, .hi = 0});
    acc = incremented;
  }
  *out = acc;
  return NULL;
}

size_t GRDU128FormatDecimal(char *buf, size_t buf_len, GRDUInt128 a) {
  if (GRDU128IsZero(a)) {
    if (buf_len < 2) return 0;
    buf[0] = '0';
    buf[1] = '\0';
    return 1;
  }
  char tmp[40];
  size_t n = 0;
  GRDUInt128 zero = {0, 0};
  while (GRDU128Cmp(a, zero) != 0) {
    unsigned __int128 v = ((unsigned __int128)a.hi << 64) | a.lo;
    unsigned __int128 q128 = v / 10u;
    uint64_t r = (uint64_t)(v % 10u);
    if (n >= sizeof(tmp)) break;
    tmp[n++] = (char)('0' + r);
    a.hi = (uint64_t)(q128 >> 64);
    a.lo = (uint64_t)q128;
  }
  if (n + 1 > buf_len) return 0;
  for (size_t i = 0; i < n; ++i) buf[i] = tmp[n - 1 - i];
  buf[n] = '\0';
  return n;
}

// ----------------------------------------------------------------------------
// Host-side reference: 256-bit field add / sub mod p
// ----------------------------------------------------------------------------

static void host_addc(uint64_t a, uint64_t b, uint64_t cin, uint64_t *sum,
                      uint64_t *cout) {
  uint64_t s = a + b;
  uint64_t c1 = (s < a) ? 1u : 0u;
  s += cin;
  uint64_t c2 = (s < cin) ? 1u : 0u;
  *sum = s;
  *cout = c1 | c2;
}

static void host_subc(uint64_t a, uint64_t b, uint64_t bin, uint64_t *diff,
                      uint64_t *bout) {
  uint64_t d = a - b;
  uint64_t b1 = (d > a) ? 1u : 0u;
  uint64_t d2 = d - bin;
  uint64_t b2 = (d2 > d) ? 1u : 0u;
  *diff = d2;
  *bout = b1 | b2;
}

GRDUInt256x64 GRDFieldAddHost(GRDUInt256x64 a, GRDUInt256x64 b) {
  GRDUInt256x64 sum;
  uint64_t carry = 0;
  host_addc(a.limbs[0], b.limbs[0], 0, &sum.limbs[0], &carry);
  host_addc(a.limbs[1], b.limbs[1], carry, &sum.limbs[1], &carry);
  host_addc(a.limbs[2], b.limbs[2], carry, &sum.limbs[2], &carry);
  host_addc(a.limbs[3], b.limbs[3], carry, &sum.limbs[3], &carry);

  int overflow = (carry != 0);
  if (!overflow) {
    overflow = (sum.limbs[3] > GRDPrimeP.limbs[3])
               || ((sum.limbs[3] == GRDPrimeP.limbs[3])
                   && ((sum.limbs[2] > GRDPrimeP.limbs[2])
                       || ((sum.limbs[2] == GRDPrimeP.limbs[2])
                           && ((sum.limbs[1] > GRDPrimeP.limbs[1])
                               || ((sum.limbs[1] == GRDPrimeP.limbs[1])
                                   && (sum.limbs[0]
                                       >= GRDPrimeP.limbs[0]))))));
  }
  if (overflow) {
    uint64_t borrow = 0;
    host_subc(sum.limbs[0], GRDPrimeP.limbs[0], 0, &sum.limbs[0], &borrow);
    host_subc(sum.limbs[1], GRDPrimeP.limbs[1], borrow, &sum.limbs[1],
              &borrow);
    host_subc(sum.limbs[2], GRDPrimeP.limbs[2], borrow, &sum.limbs[2],
              &borrow);
    host_subc(sum.limbs[3], GRDPrimeP.limbs[3], borrow, &sum.limbs[3],
              &borrow);
  }
  return sum;
}

GRDUInt256x64 GRDFieldSubHost(GRDUInt256x64 a, GRDUInt256x64 b) {
  GRDUInt256x64 diff;
  uint64_t borrow = 0;
  host_subc(a.limbs[0], b.limbs[0], 0, &diff.limbs[0], &borrow);
  host_subc(a.limbs[1], b.limbs[1], borrow, &diff.limbs[1], &borrow);
  host_subc(a.limbs[2], b.limbs[2], borrow, &diff.limbs[2], &borrow);
  host_subc(a.limbs[3], b.limbs[3], borrow, &diff.limbs[3], &borrow);

  if (borrow) {
    uint64_t carry = 0;
    host_addc(diff.limbs[0], GRDPrimeP.limbs[0], 0, &diff.limbs[0], &carry);
    host_addc(diff.limbs[1], GRDPrimeP.limbs[1], carry, &diff.limbs[1],
              &carry);
    host_addc(diff.limbs[2], GRDPrimeP.limbs[2], carry, &diff.limbs[2],
              &carry);
    host_addc(diff.limbs[3], GRDPrimeP.limbs[3], carry, &diff.limbs[3],
              &carry);
  }
  return diff;
}

// ----------------------------------------------------------------------------
// Host-side reference: 256-bit field multiplication (mod p)
//
// Algorithm:
//   1. 4×4 schoolbook → 8-limb (512-bit) product.
//   2. Secp256k1 fast reduction (one pass, careful carry chain).
//      Reference: Bitcoin Core secp256k1_fe_reduce_256 (5x52 form,
//      translated to 4x64).
//   3. Conditional subtract p if result >= p.
// ----------------------------------------------------------------------------

GRDUInt256x64 GRDFieldMulHost(GRDUInt256x64 a, GRDUInt256x64 b) {
  // Step 1: schoolbook 4×4 multiplication.
  uint64_t r[8] = {0, 0, 0, 0, 0, 0, 0, 0};

  for (int i = 0; i < 4; ++i) {
    uint64_t carry = 0;
    for (int j = 0; j < 4; ++j) {
      unsigned __int128 prod = (unsigned __int128)a.limbs[i]
                               * (unsigned __int128)b.limbs[j];
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

  // Step 2: iterative secp256k1 reduction.
//   r = R_low + R_high * c (mod p), iterated until r fits in 256 bits.
//   c = 2^32 + 977. Each iteration reduces the bit-width by 32.
  const uint64_t c = (1ull << 32) + 977ull;
  while (r[4] != 0 || r[5] != 0 || r[6] != 0 || r[7] != 0) {
    uint64_t new_r[8] = {r[0], r[1], r[2], r[3], 0, 0, 0, 0};
    uint64_t carry = 0;
    // new_r += R_high * c, per-limb
    for (int i = 0; i < 4; ++i) {
      unsigned __int128 prod = (unsigned __int128)r[4 + i]
                               * (unsigned __int128)c;
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
    r[5] = 0;
    r[6] = 0;
    r[7] = 0;
  }

  // Step 3: conditional subtract p. The iterative step 2 brings the
  // value down to <= 5 limbs. We subtract p until result < p.
  GRDUInt256x64 lo = {{r[0], r[1], r[2], r[3]}};
  while (r[4] != 0 || GRDGte(lo, GRDPrimeP)) {
    uint64_t borrow = 0;
    lo.limbs[0] = lo.limbs[0] - GRDPrimeP.limbs[0];
    borrow = (lo.limbs[0] > UINT64_MAX - GRDPrimeP.limbs[0]) ? 1u : 0u;
    lo.limbs[1] = lo.limbs[1] - GRDPrimeP.limbs[1] - borrow;
    borrow = (lo.limbs[1] > UINT64_MAX - GRDPrimeP.limbs[1] - borrow) ? 1u : 0u;
    lo.limbs[2] = lo.limbs[2] - GRDPrimeP.limbs[2] - borrow;
    borrow = (lo.limbs[2] > UINT64_MAX - GRDPrimeP.limbs[2] - borrow) ? 1u : 0u;
    lo.limbs[3] = lo.limbs[3] - GRDPrimeP.limbs[3] - borrow;
    if (r[4] != 0) r[4] -= 1;
  }

  return lo;
}

GRDUInt256x64 GRDFieldSqrHost(GRDUInt256x64 a) {
  return GRDFieldMulHost(a, a);
}

GRDUInt256x64 GRDFieldInvHost(GRDUInt256x64 a) {
  // Exponent = p - 2 =
  //   0xFFFFFFFFFFFFFFFF FFFFFFFFFFFFFFFF FFFFFFFFFFFFFFFF FFFFFFFEFFFFFC2D
  GRDUInt256x64 result = {{1, 0, 0, 0}};
  GRDUInt256x64 base = a;
  for (int i = 0; i < 256; ++i) {
    const uint64_t kExpLo = 0xFFFFFFFEFFFFFC2Dul;
    const uint64_t kExp1 = 0xFFFFFFFFFFFFFFFFul;
    const uint64_t kExp2 = 0xFFFFFFFFFFFFFFFFul;
    const uint64_t kExp3 = 0xFFFFFFFFFFFFFFFFul;
    uint64_t bit;
    if (i < 64) bit = (kExpLo >> i) & 1ul;
    else if (i < 128) bit = (kExp1 >> (i - 64)) & 1ul;
    else if (i < 192) bit = (kExp2 >> (i - 128)) & 1ul;
    else bit = (kExp3 >> (i - 192)) & 1ul;
    if (bit) result = GRDFieldMulHost(result, base);
    if (i < 255) base = GRDFieldSqrHost(base);
  }
  return result;
}

// ----------------------------------------------------------------------------
// Host-side EC point arithmetic
// ----------------------------------------------------------------------------

const GRDEcPoint GRDSecp256k1G = {
    {{0x59F2815B16F81798ull, 0x029BFCDB2DCE28D9ull, 0x55A06295CE870B07ull,
      0x79BE667EF9DCBBACull}},  // Gx little-endian limbs
    {{0x9C47D08FFB10D4B8ull, 0xFD17B448A6855419ull, 0x5DA4FBFC0E1108A8ull,
      0x483ADA7726A3C465ull}},  // Gy little-endian limbs
    {{1, 0, 0, 0}}
};

GRDEcPoint GRDEcDoubleHost(GRDEcPoint p) {
  if (GRDIsZero(p.Z)) return p;

  GRDUInt256x64 A = GRDFieldSqrHost(p.X);
  GRDUInt256x64 B = GRDFieldSqrHost(p.Y);
  GRDUInt256x64 C = GRDFieldSqrHost(B);

  GRDUInt256x64 t = GRDFieldAddHost(p.X, B);
  t = GRDFieldSqrHost(t);
  t = GRDFieldSubHost(t, A);
  t = GRDFieldSubHost(t, C);
  GRDUInt256x64 D = GRDFieldAddHost(t, t);

  GRDUInt256x64 E = GRDFieldAddHost(GRDFieldAddHost(A, A), A);

  GRDEcPoint r;
  r.X = GRDFieldSubHost(GRDFieldSqrHost(E), GRDFieldAddHost(D, D));
  r.Y = GRDFieldSubHost(D, r.X);
  r.Y = GRDFieldMulHost(E, r.Y);
  r.Y = GRDFieldSubHost(r.Y, GRDFieldAddHost(GRDFieldAddHost(GRDFieldAddHost(C, C),
                                                              GRDFieldAddHost(C, C)),
                                              GRDFieldAddHost(GRDFieldAddHost(C, C),
                                                              GRDFieldAddHost(C, C))));
  r.Z = GRDFieldMulHost(GRDFieldAddHost(p.Y, p.Y), p.Z);
  return r;
}

GRDEcPoint GRDEcAddHost(GRDEcPoint p, GRDEcPoint q) {
  if (GRDIsZero(p.Z)) return q;
  if (GRDIsZero(q.Z)) return p;

  GRDUInt256x64 Z1Z1 = GRDFieldSqrHost(p.Z);
  GRDUInt256x64 Z2Z2 = GRDFieldSqrHost(q.Z);
  GRDUInt256x64 U1 = GRDFieldMulHost(p.X, Z2Z2);
  GRDUInt256x64 U2 = GRDFieldMulHost(q.X, Z1Z1);
  GRDUInt256x64 S1 = GRDFieldMulHost(p.Y, GRDFieldMulHost(Z2Z2, q.Z));
  GRDUInt256x64 S2 = GRDFieldMulHost(q.Y, GRDFieldMulHost(Z1Z1, p.Z));
  GRDUInt256x64 H = GRDFieldSubHost(U2, U1);
  GRDUInt256x64 I = GRDFieldAddHost(GRDFieldAddHost(H, H),
                                   GRDFieldSqrHost(H));
  GRDUInt256x64 J = GRDFieldMulHost(H, I);
  GRDUInt256x64 rr = GRDFieldSubHost(S2, S1);
  GRDUInt256x64 V = GRDFieldMulHost(U1, GRDFieldSqrHost(H));
  GRDUInt256x64 r2 = GRDFieldSubHost(GRDFieldSubHost(GRDFieldSqrHost(rr), J),
                                     GRDFieldAddHost(V, V));

  GRDEcPoint r;
  r.X = GRDFieldMulHost(I, r2);
  r.Y = GRDFieldSubHost(GRDFieldMulHost(rr, GRDFieldSubHost(V, r2)),
                         GRDFieldMulHost(S1, J));
  r.Z = GRDFieldMulHost(GRDFieldMulHost(p.Z, q.Z), H);
  return r;
}

GRDEcPoint GRDEcAddMixedHost(GRDEcPoint p, GRDEcPoint q) {
  if (GRDIsZero(p.Z)) return q;
  if (GRDIsZero(q.Z)) return p;

  GRDUInt256x64 Z1Z1 = GRDFieldSqrHost(p.Z);
  GRDUInt256x64 U2 = GRDFieldMulHost(q.X, Z1Z1);
  GRDUInt256x64 S2 = GRDFieldMulHost(q.Y, GRDFieldMulHost(Z1Z1, p.Z));
  GRDUInt256x64 H = GRDFieldSubHost(U2, p.X);
  GRDUInt256x64 I = GRDFieldAddHost(GRDFieldAddHost(H, H),
                                   GRDFieldSqrHost(H));
  GRDUInt256x64 J = GRDFieldMulHost(H, I);
  GRDUInt256x64 V = GRDFieldMulHost(p.X, GRDFieldSqrHost(H));
  GRDUInt256x64 r2 = GRDFieldSubHost(GRDFieldSubHost(GRDFieldSqrHost(S2), J),
                                     GRDFieldAddHost(V, V));

  GRDEcPoint r;
  r.X = GRDFieldMulHost(I, r2);
  r.Y = GRDFieldSubHost(GRDFieldMulHost(S2, GRDFieldSubHost(V, r2)),
                         GRDFieldMulHost(S2, J));
  r.Z = GRDFieldAddHost(GRDFieldAddHost(p.Z, p.Z),
                         GRDFieldMulHost(GRDFieldAddHost(H, H), p.Z));
  return r;
}

GRDEcPoint GRDEcNegHost(GRDEcPoint p) {
  GRDEcPoint r;
  r.X = p.X;
  r.Y = GRDFieldSubHost(GRDPrimeP, p.Y);
  r.Z = p.Z;
  return r;
}

GRDUInt256x64 GRDReduceModNHost(GRDUInt256x64 a) {
  while (GRDGte(a, GRDOrderN)) {
    uint64_t borrow = 0;
    a.limbs[0] = a.limbs[0] - GRDOrderN.limbs[0];
    borrow = (a.limbs[0] > UINT64_MAX - GRDOrderN.limbs[0]) ? 1u : 0u;
    a.limbs[1] = a.limbs[1] - GRDOrderN.limbs[1] - borrow;
    borrow = (a.limbs[1] > UINT64_MAX - GRDOrderN.limbs[1] - borrow) ? 1u : 0u;
    a.limbs[2] = a.limbs[2] - GRDOrderN.limbs[2] - borrow;
    borrow = (a.limbs[2] > UINT64_MAX - GRDOrderN.limbs[2] - borrow) ? 1u : 0u;
    a.limbs[3] = a.limbs[3] - GRDOrderN.limbs[3] - borrow;
  }
  return a;
}

GRDEcPoint GRDScalarMulHost(GRDEcPoint p, GRDUInt256x64 k) {
  GRDEcPoint result = {{0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}};  // identity
  bool found_one = false;
  for (int i = 255; i >= 0; --i) {
    if (found_one) result = GRDEcDoubleHost(result);
    uint64_t bit;
    if (i < 64) bit = (k.limbs[0] >> i) & 1ul;
    else if (i < 128) bit = (k.limbs[1] >> (i - 64)) & 1ul;
    else if (i < 192) bit = (k.limbs[2] >> (i - 128)) & 1ul;
    else bit = (k.limbs[3] >> (i - 192)) & 1ul;
    if (bit) {
      if (found_one) result = GRDEcAddHost(result, p);
      else {
        result = p;
        found_one = true;
      }
    }
  }
  return result;
}

GRDEcPoint GRDScalarMulGHost(GRDUInt256x64 k) {
  return GRDScalarMulHost(GRDSecp256k1G, k);
}

// ----------------------------------------------------------------------------
// Comparison / equality (host-side mirror of metal/secp256k1.metal)
// ----------------------------------------------------------------------------

bool GRDEq(GRDUInt256x64 a, GRDUInt256x64 b) {
  return a.limbs[0] == b.limbs[0] && a.limbs[1] == b.limbs[1]
         && a.limbs[2] == b.limbs[2] && a.limbs[3] == b.limbs[3];
}

bool GRDIsZero(GRDUInt256x64 a) {
  return a.limbs[0] == 0 && a.limbs[1] == 0 && a.limbs[2] == 0
         && a.limbs[3] == 0;
}

bool GRDGte(GRDUInt256x64 a, GRDUInt256x64 b) {
  if (a.limbs[3] != b.limbs[3]) return a.limbs[3] > b.limbs[3];
  if (a.limbs[2] != b.limbs[2]) return a.limbs[2] > b.limbs[2];
  if (a.limbs[1] != b.limbs[1]) return a.limbs[1] > b.limbs[1];
  return a.limbs[0] >= b.limbs[0];
}

// ----------------------------------------------------------------------------
// Debug: render a UInt256x64 as big-endian hex
// ----------------------------------------------------------------------------

void GRDU256Hex(char *out, size_t out_len, GRDUInt256x64 a) {
  if (out_len < 65) return;
  static const char *hex = "0123456789abcdef";
  size_t pos = 0;
  for (int i = 3; i >= 0; --i) {
    for (int j = 60; j >= 0; j -= 4) {
      out[pos++] = hex[(a.limbs[i] >> j) & 0xF];
    }
  }
  out[pos] = '\0';
}