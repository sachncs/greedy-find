// tests/kat/variant_kat.c — KAT for variant generation + VariantIndex.
//
// Verifies GRDGenerateVariants produces 512 variants (256 powers of two
// + 256 cumulative sums mod n), and GRDComputeVariantXBytes produces
// a sane compressed X-bytes buffer for the privkey=1 (G) target.

#import <Foundation/Foundation.h>

#include "pubkey.h"
#include "sweep.h"
#include "ecc.h"

static int g_failures = 0;

#define GRD_KAT_FAIL0(label, msg)                                  \
  do {                                                              \
    fprintf(stderr, "FAIL [%s] %s\n", (label), (msg));             \
    g_failures++;                                                   \
  } while (0)
#define GRD_KAT_FAIL1(label, fmt, a)                                \
  do {                                                              \
    fprintf(stderr, "FAIL [%s] " fmt "\n", (label), (a));            \
    g_failures++;                                                   \
  } while (0)
#define GRD_KAT_FAIL2(label, fmt, a, b)                              \
  do {                                                              \
    fprintf(stderr, "FAIL [%s] " fmt "\n", (label), (a), (b));       \
    g_failures++;                                                   \
  } while (0)
#define GRD_KAT_FAIL4(label, fmt, a, b, c, d)                        \
  do {                                                              \
    fprintf(stderr, "FAIL [%s] " fmt "\n", (label), (a), (b), (c), (d)); \
    g_failures++;                                                   \
  } while (0)

static void test_variant_count(void) {
  size_t count = 0;
  const GRDVariant *v = GRDGenerateVariants(&count);
  if (count != 512) {
    GRD_KAT_FAIL1("variant_count", "got %zu, want 512", count);
  }
  if (v == NULL) GRD_KAT_FAIL0("variant_count", "NULL pointer");
}

static void test_variant_powers_of_two(void) {
  // The first 256 variants are 2^i mod n for i in 0..255.
  // 2^0 mod n = 1, 2^1 = 2, 2^2 = 4, etc.
  size_t count = 0;
  const GRDVariant *v = GRDGenerateVariants(&count);

  GRDUInt256x64 expected;
  expected.limbs[0] = 1; expected.limbs[1] = 0;
  expected.limbs[2] = 0; expected.limbs[3] = 0;
  if (!GRDEq(v[0].V, expected))
    fprintf(stderr, "FAIL [v[0]] want 1, got (%llu, %llu, %llu, %llu)\n",
            v[0].V.limbs[0], v[0].V.limbs[1], v[0].V.limbs[2], v[0].V.limbs[3]),
      g_failures++;

  expected.limbs[0] = 2; expected.limbs[1] = 0;
  expected.limbs[2] = 0; expected.limbs[3] = 0;
  if (!GRDEq(v[1].V, expected))
    GRD_KAT_FAIL0("v[1]", "want 2");

  expected.limbs[0] = 4; expected.limbs[1] = 0;
  expected.limbs[2] = 0; expected.limbs[3] = 0;
  if (!GRDEq(v[2].V, expected))
    GRD_KAT_FAIL0("v[2]", "want 4");
}

static void test_variant_cumulative_sums(void) {
  // Variants 256..511 are cumulative sums: 2^(i+1) - 1 mod n.
  // Sum at i=0: 2^1 - 1 = 1
  // Sum at i=1: 1 + 2 = 3
  // Sum at i=2: 3 + 4 = 7
  // Sum at i=3: 7 + 8 = 15
  size_t count = 0;
  const GRDVariant *v = GRDGenerateVariants(&count);

  struct { uint64_t lo; } expect[4] = {{1}, {3}, {7}, {15}};
  for (int i = 0; i < 4; ++i) {
    if (v[256 + i].V.limbs[0] != expect[i].lo ||
        v[256 + i].V.limbs[1] != 0 ||
        v[256 + i].V.limbs[2] != 0 ||
        v[256 + i].V.limbs[3] != 0) {
      fprintf(stderr,
              "FAIL [v[256+i]] i=%d want %llu, got (%llu, %llu, %llu, %llu)\n",
              i, expect[i].lo,
              v[256 + i].V.limbs[0], v[256 + i].V.limbs[1],
              v[256 + i].V.limbs[2], v[256 + i].V.limbs[3]);
      g_failures++;
    }
  }
}

static void test_variant_x_bytes_d1(void) {
  // d=1 → G. The variant X-bytes for all variants should be the
  // X-coordinate of (G - V·G) = (1-V)G, so a function of V.
  // For V=0, this is just Gx. For V=1, (1-1)G = identity, X=0.
  // We just verify that GRDComputeVariantXBytes doesn't crash and
  // returns the expected length.
  size_t count = 0;
  const GRDVariant *v = GRDGenerateVariants(&count);

  uint8_t pubkey[33] = {
      0x02,
      0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62, 0x95,
      0xCE, 0x87, 0x0B, 0x07, 0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
      0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98,
  };
  NSData *xs = GRDComputeVariantXBytes(pubkey, v, 16, NULL);
  if (xs == NULL) {
    GRD_KAT_FAIL0("variant_x_bytes(d=1)", "NULL result");
    return;
  }
  if ([xs length] != 16 * 32) {
    fprintf(stderr, "FAIL [variant_x_bytes(d=1)] length=%lu, want %d\n",
            (unsigned long)[xs length], 16 * 32);
    g_failures++;
  }
}

int main(void) {
  test_variant_count();
  test_variant_powers_of_two();
  test_variant_cumulative_sums();
  test_variant_x_bytes_d1();
  if (g_failures) {
    fprintf(stderr, "variant_kat: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("variant_kat: all tests passed\n");
  return 0;
}