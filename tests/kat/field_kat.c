// tests/kat/field_kat.c — Known-answer tests for field add/sub/mul.
//
// Verifies the C host-side reference implementation against
// hand-computed expected values. The Metal implementation in
// metal/secp256k1.metal is mirrored limb-for-limb so any divergence
// surfaces during end-to-end differential testing against `find`.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ecc.h"

static int g_failures = 0;

#define GRD_KAT_FAIL(label, got, want)                                    \
  do {                                                                    \
    char got_hex[65], want_hex[65];                                       \
    GRDU256Hex(got_hex, sizeof(got_hex), (got));                          \
    GRDU256Hex(want_hex, sizeof(want_hex), (want));                       \
    fprintf(stderr,                                                        \
            "FAIL [%s]: got  %s\n"                                         \
            "         want %s\n",                                          \
            (label), got_hex, want_hex);                                   \
    g_failures++;                                                          \
  } while (0)

#define GRD_KAT_ASSERT_EQ(label, got, want)                                \
  do {                                                                     \
    if (!GRDEq((got), (want))) {                                            \
      GRD_KAT_FAIL((label), (got), (want));                                 \
    }                                                                      \
  } while (0)

static GRDUInt256x64 make_u256(uint64_t l0, uint64_t l1, uint64_t l2,
                               uint64_t l3) {
  GRDUInt256x64 v = {{l0, l1, l2, l3}};
  return v;
}

// Identity / known constant tests ------------------------------------------

static void test_zero(void) {
  GRDUInt256x64 zero = make_u256(0, 0, 0, 0);
  GRDUInt256x64 one = make_u256(1, 0, 0, 0);
  GRD_KAT_ASSERT_EQ("add(0, 0)", GRDFieldAddHost(zero, zero), zero);
  GRD_KAT_ASSERT_EQ("add(0, 1)", GRDFieldAddHost(zero, one), one);
  GRD_KAT_ASSERT_EQ("add(1, 0)", GRDFieldAddHost(one, zero), one);
  GRD_KAT_ASSERT_EQ("sub(0, 0)", GRDFieldSubHost(zero, zero), zero);
  GRD_KAT_ASSERT_EQ("sub(1, 1)", GRDFieldSubHost(one, one), zero);
}

// p-1 = (p-1, 0, 0, 0) tests ---------------------------------------------

static GRDUInt256x64 p_minus_one(void) {
  // p = 0xFFFFFFFEFFFFFC2F, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
  //     0xFFFFFFFFFFFFFFFF
  // p - 1 = 0xFFFFFFFEFFFFFC2E, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
  //         0xFFFFFFFFFFFFFFFF
  return make_u256(0xFFFFFFFEFFFFFC2Eull, 0xFFFFFFFFFFFFFFFFull,
                   0xFFFFFFFFFFFFFFFFull, 0xFFFFFFFFFFFFFFFFull);
}

static void test_p_boundary(void) {
  GRDUInt256x64 zero = make_u256(0, 0, 0, 0);
  GRDUInt256x64 one = make_u256(1, 0, 0, 0);
  GRDUInt256x64 pm1 = p_minus_one();

  // (p-1) + 1 == 0 mod p
  GRD_KAT_ASSERT_EQ("add(p-1, 1)", GRDFieldAddHost(pm1, one), zero);
  // 1 + (p-1) == 0 mod p
  GRD_KAT_ASSERT_EQ("add(1, p-1)", GRDFieldAddHost(one, pm1), zero);
  // 0 - 1 == p-1 mod p
  GRD_KAT_ASSERT_EQ("sub(0, 1)", GRDFieldSubHost(zero, one), pm1);
  // (p-1) - (p-1) == 0 mod p
  GRD_KAT_ASSERT_EQ("sub(p-1, p-1)", GRDFieldSubHost(pm1, pm1), zero);
  // (p-1) - 0 == p-1 mod p
  GRD_KAT_ASSERT_EQ("sub(p-1, 0)", GRDFieldSubHost(pm1, zero), pm1);
  // 0 - (p-1) == 1 mod p
  GRD_KAT_ASSERT_EQ("sub(0, p-1)", GRDFieldSubHost(zero, pm1), one);
  // (p-1) + (p-1) == p-2 mod p
  GRD_KAT_ASSERT_EQ("add(p-1, p-1)", GRDFieldAddHost(pm1, pm1),
                    make_u256(0xFFFFFFFEFFFFFC2Dull, 0xFFFFFFFFFFFFFFFFull,
                              0xFFFFFFFFFFFFFFFFull, 0xFFFFFFFFFFFFFFFFull));
}

// u128 parsing / formatting -------------------------------------------------

static void test_u128_parse(void) {
  GRDUInt128 v;
  const char *err = GRDU128ParseDecimal(&v, "12345678901234567890");
  if (err) {
    fprintf(stderr, "FAIL [parse]: %s\n", err);
    g_failures++;
    return;
  }
  // 12345678901234567890 = 0xAB54A98CEB1F0AD2 (fits in 64 bits, hi = 0)
  if (v.lo != 0xAB54A98CEB1F0AD2ull || v.hi != 0) {
    fprintf(stderr,
            "FAIL [parse 12345678901234567890]: got lo=%llx hi=%llx\n",
            (unsigned long long)v.lo, (unsigned long long)v.hi);
    g_failures++;
  }

  char buf[40];
  size_t n = GRDU128FormatDecimal(buf, sizeof(buf), v);
  if (n != 20 || strcmp(buf, "12345678901234567890") != 0) {
    fprintf(stderr, "FAIL [format]: got '%s' (n=%zu)\n", buf, n);
    g_failures++;
  }
}

static void test_mul_sqr(void) {
  GRDUInt256x64 zero = make_u256(0, 0, 0, 0);
  GRDUInt256x64 one = make_u256(1, 0, 0, 0);
  GRDUInt256x64 two = make_u256(2, 0, 0, 0);
  GRDUInt256x64 pm1 = p_minus_one();

  // 0 * x == 0
  GRD_KAT_ASSERT_EQ("mul(0, 1)", GRDFieldMulHost(zero, one), zero);
  GRD_KAT_ASSERT_EQ("mul(1, 0)", GRDFieldMulHost(one, zero), zero);
  // 1 * 1 == 1
  GRD_KAT_ASSERT_EQ("mul(1, 1)", GRDFieldMulHost(one, one), one);
  // 2 * 2 == 4
  GRD_KAT_ASSERT_EQ("mul(2, 2)", GRDFieldMulHost(two, two),
                    make_u256(4, 0, 0, 0));
  // 2 * (p-1) == -2 mod p == p-2
  GRD_KAT_ASSERT_EQ("mul(2, p-1)", GRDFieldMulHost(two, pm1),
                    make_u256(0xFFFFFFFEFFFFFC2Dull, 0xFFFFFFFFFFFFFFFFull,
                              0xFFFFFFFFFFFFFFFFull, 0xFFFFFFFFFFFFFFFFull));
  // (p-1) * (p-1) == 1 (since -1 * -1 == 1)
  GRD_KAT_ASSERT_EQ("mul(p-1, p-1)", GRDFieldMulHost(pm1, pm1), one);
  // sqr(2) == 4
  GRD_KAT_ASSERT_EQ("sqr(2)", GRDFieldSqrHost(two), make_u256(4, 0, 0, 0));
  // sqr(0) == 0
  GRD_KAT_ASSERT_EQ("sqr(0)", GRDFieldSqrHost(zero), zero);
  // sqr(p-1) == 1
  GRD_KAT_ASSERT_EQ("sqr(p-1)", GRDFieldSqrHost(pm1), one);
}

static void test_u128_arith(void) {
  GRDUInt128 a = {.lo = 0xFFFFFFFFFFFFFFFFull, .hi = 1ull};
  GRDUInt128 b = {.lo = 1, .hi = 0};
  GRDUInt128 sum;
  GRDU128Add(&sum, a, b);
  if (sum.lo != 0 || sum.hi != 2) {
    fprintf(stderr, "FAIL [u128 add carry]: lo=%llx hi=%llx\n",
            (unsigned long long)sum.lo, (unsigned long long)sum.hi);
    g_failures++;
  }
}

// Main ----------------------------------------------------------------------

int main(void) {
  test_zero();
  test_p_boundary();
  test_mul_sqr();
  test_u128_parse();
  test_u128_arith();

  if (g_failures) {
    fprintf(stderr, "field_kat: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("field_kat: all tests passed\n");
  return 0;
}