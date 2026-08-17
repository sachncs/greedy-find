// tests/kat/ec_kat.c — KAT for EC point operations (host-side reference).
//
// Verifies the C host-side reference implementation against Python's
// known-good results.

#include <stdio.h>
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

#define GRD_KAT_ASSERT_EQ_XYZ(label, gotP, wantP)                          \
  do {                                                                     \
    if (!GRDEq((gotP).X, (wantP).X) || !GRDEq((gotP).Y, (wantP).Y) ||   \
        !GRDEq((gotP).Z, (wantP).Z)) {                                     \
      GRD_KAT_FAIL((label), (gotP).X, (wantP).X);                           \
      GRD_KAT_FAIL((label), (gotP).Y, (wantP).Y);                           \
      GRD_KAT_FAIL((label), (gotP).Z, (wantP).Z);                           \
    }                                                                      \
  } while (0)

static GRDEcPoint aff(double x, double y, double z) {
  (void)x;
  (void)y;
  (void)z;
  GRDEcPoint r = {{0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}};
  return r;
}

static void test_double_g(void) {
  // 2*G Jacobian coords, computed via the secp256k1 doubling formula
  // (Python reference). Note these are projective, NOT affine — the
  // affine form divides X3 / Z3^2.
  GRDUInt256x64 g_x = {{0x91D40444B365AFC2ull, 0xB68F88FEF695E2C7ull,
                       0x2191843D1FA9DB55ull, 0x7D152C041EA8E1DCull}};
  GRDUInt256x64 g_y = {{0x5FE89164BFADCBDBull, 0x43BF633E1B1383F8ull,
                       0x6F5FD7E4BF60DB4Aull, 0x56915849F52CC8F7ull}};
  GRDUInt256x64 g_z = {{0x388FA11FF621A970ull, 0xFA2F68914D0AA833ull,
                       0xBB49F7F81C221151ull, 0x9075B4EE4D4788CAull}};
  GRDEcPoint expected = {g_x, g_y, g_z};
  GRDEcPoint got = GRDEcDoubleHost(GRDSecp256k1G);
  GRD_KAT_ASSERT_EQ_XYZ("2G", got, expected);
}

int main(void) {
  test_double_g();
  (void)aff;  // silence unused

  if (g_failures) {
    fprintf(stderr, "ec_kat: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("ec_kat: all tests passed\n");
  return 0;
}