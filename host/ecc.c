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

/**
 * Parses a non-negative decimal integer string into a u128. Returns
 * NULL on success, or a static error string on failure.
 */
const char *GRDU128ParseDecimal(GRDUInt128 *out, const char *s) {
  if (!s || !*s) return "empty string";
  GRDUInt128 acc = {0, 0};
  GRDUInt128 ten = {.lo = 10, .hi = 0};
  for (const char *p = s; *p; ++p) {
    if (*p < '0' || *p > '9') return "non-decimal character";
    uint8_t digit = (uint8_t)(*p - '0');
    // acc = acc * 10 + digit
    unsigned __int128 mul = (unsigned __int128)acc.lo * 10ull;
    GRDUInt128 tmp = {.lo = (uint64_t)mul, .hi = acc.hi * 10ull
                                                 + (uint64_t)(mul >> 64)};
    GRDUInt128 incremented;
    GRDU128Add(&incremented, tmp,
 (GRDUInt128){.lo = digit, .hi = 0});
    acc = incremented;
    (void)ten;
  }
  *out = acc;
  return NULL;
}

/**
 * Formats a u128 as a decimal string into @c buf (which must be at least
 * 40 bytes). Returns the number of bytes written (excluding the NUL).
 */
size_t GRDU128FormatDecimal(char *buf, size_t buf_len, GRDUInt128 a) {
  if (GRDU128IsZero(a)) {
    if (buf_len < 2) return 0;
    buf[0] = '0';
    buf[1] = '\0';
    return 1;
  }
  // Repeated divmod by 10 — naive but trivial and only used in the
  // cold path (telemetry, --version, error messages).
  char tmp[40];
  size_t n = 0;
  GRDUInt128 zero = {0, 0};
  GRDUInt128 ten = {.lo = 10, .hi = 0};
  while (GRDU128Cmp(a, zero) != 0) {
    unsigned __int128 v = ((unsigned __int128)a.hi << 64) | a.lo;
    unsigned __int128 q128 = v / 10u;
    uint64_t r = (uint64_t)(v % 10u);
    if (n >= sizeof(tmp)) break;  // unreachable for u128
    tmp[n++] = (char)('0' + r);
    a.hi = (uint64_t)(q128 >> 64);
    a.lo = (uint64_t)q128;
    (void)ten;
  }
  if (n + 1 > buf_len) return 0;
  for (size_t i = 0; i < n; ++i) buf[i] = tmp[n - 1 - i];
  buf[n] = '\0';
  return n;
}

// ----------------------------------------------------------------------------
// Host-side reference: 256-bit field add / sub mod p
//
// These mirror metal/secp256k1.metal so the KAT can validate either
// side. They are intentionally NOT constant-time.
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
    host_subc(sum.limbs[1], GRDPrimeP.limbs[1], borrow, &sum.limbs[1], &borrow);
    host_subc(sum.limbs[2], GRDPrimeP.limbs[2], borrow, &sum.limbs[2], &borrow);
    host_subc(sum.limbs[3], GRDPrimeP.limbs[3], borrow, &sum.limbs[3], &borrow);
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
  // Big-endian output, MSB first. Each limb becomes 16 hex chars.
  static const char *hex = "0123456789abcdef";
  size_t pos = 0;
  for (int i = 3; i >= 0; --i) {
    for (int j = 60; j >= 0; j -= 4) {
      out[pos++] = hex[(a.limbs[i] >> j) & 0xF];
    }
  }
  out[pos] = '\0';
}