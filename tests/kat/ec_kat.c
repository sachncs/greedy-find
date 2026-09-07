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
  // 2*G in affine coordinates (Z=1). Cross-checked against
  // bitcoin-core/secp256k1's own 2*G output (see host/ecc.c,
  // GRDEcDoubleHost). The host's reference implementation uses
  // libsecp256k1, which serialises/deserialises through affine,
  // so the comparison is in affine.
  //
  // Reference (standard secp256k1 2*G):
  //   X = 0xC6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5
  //   Y = 0x1AE168FEA63DC339A3C58419466CEAEEF7F632653266D0E1236431A950CFE52A
  // Decomposed into little-endian 64-bit limbs (limbs[3] = top):
  //   X.limbs[3..0] = C6047F9441ED7D6D, 3045406E95C07CD8,
  //                   5C778E4B8CEF3CA7, ABAC09B95C709EE5
  //   Y.limbs[3..0] = 1AE168FEA63DC339, A3C58419466CEAEE,
  //                   F7F632653266D0E1, 236431A950CFE52A
  GRDUInt256x64 g2_x = {{0xABAC09B95C709EE5ull, 0x5C778E4B8CEF3CA7ull,
                         0x3045406E95C07CD8ull, 0xC6047F9441ED7D6Dull}};
  GRDUInt256x64 g2_y = {{0x236431A950CFE52Aull, 0xF7F632653266D0E1ull,
                         0xA3C58419466CEAEEull, 0x1AE168FEA63DC339ull}};
  GRDUInt256x64 g2_z = {{1u, 0u, 0u, 0u}};
  GRDEcPoint expected = {g2_x, g2_y, g2_z};
  GRDEcPoint got = GRDEcDoubleHost(GRDSecp256k1G);
  GRD_KAT_ASSERT_EQ_XYZ("2G", got, expected);
}

static void test_double_g_known_answer(void) {
  // The 2*G affine X is the well-known constant
  // 0xC6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5
  // (BIP340 / secp256k1 documentation). Independently verify our
  // host's 2*G output matches this byte-for-byte, not just against
  // a second libsecp256k1-derived value.
  static const uint8_t kExpectedX[32] = {
    0xC6, 0x04, 0x7F, 0x94, 0x41, 0xED, 0x7D, 0x6D,
    0x30, 0x45, 0x40, 0x6E, 0x95, 0xC0, 0x7C, 0xD8,
    0x5C, 0x77, 0x8E, 0x4B, 0x8C, 0xEF, 0x3C, 0xA7,
    0xAB, 0xAC, 0x09, 0xB9, 0x5C, 0x70, 0x9E, 0xE5,
  };
  GRDEcPoint got = GRDEcDoubleHost(GRDSecp256k1G);
  uint8_t got_x_be[32];
  for (int i = 0; i < 4; ++i) {
    uint64_t limb = got.X.limbs[3 - i];
    for (int j = 0; j < 8; ++j) {
      got_x_be[i * 8 + j] = (uint8_t)(limb >> ((7 - j) * 8));
    }
  }
  if (memcmp(got_x_be, kExpectedX, 32) != 0) {
    fprintf(stderr,
            "FAIL [2G_known_X]: 2*G X does not match secp256k1 reference\n");
    fprintf(stderr, "         got  ");
    for (int i = 0; i < 32; ++i) fprintf(stderr, "%02x", got_x_be[i]);
    fprintf(stderr, "\n         want ");
    for (int i = 0; i < 32; ++i) fprintf(stderr, "%02x", kExpectedX[i]);
    fprintf(stderr, "\n");
    g_failures++;
  }
}

int main(void) {
  test_double_g();
  test_double_g_known_answer();
  (void)aff;  // silence unused

  if (g_failures) {
    fprintf(stderr, "ec_kat: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("ec_kat: all tests passed\n");
  return 0;
}