// tools/gen_pubkey.c — derive the compressed secp256k1 public key for a
// given decimal private scalar.
//
// Usage:
//   gen_pubkey <decimal-d>
//
// Prints the 33-byte compressed pubkey as 66 lowercase hex characters on
// stdout. Rejects d == 0 and d >= n with exit code 64 (matches cli.md).
//
// Built standalone with the same Homebrew libsecp256k1 that the rest of
// the host code uses; no Foundation or Metal dependency.

#include "gen_pubkey.h"

#include <secp256k1.h>

#include <stdio.h>
#include <string.h>

// secp256k1 group order n, big-endian. We only need this to reject
// out-of-range scalars up front; the libsecp256k1_ec_pubkey_create call
// itself would also reject them, but with a less informative error.
static const uint8_t kSecp256k1N[32] = {
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
    0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
    0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
};

int grd_parse_decimal_scalar(const char *dec, uint8_t out[32]) {
  if (dec == NULL || dec[0] == '\0') {
    return -1;
  }
  // Strip leading zeros for validation; the result is zero iff every digit
  // was '0'.
  const char *p = dec;
  while (*p == '0') {
    p++;
  }
  if (*p == '\0') {
    // Scalar is exactly zero; secp256k1 forbids d == 0.
    return -2;
  }
  size_t digit_count = strlen(p);
  if (digit_count > 78) {
    // 2^256 ≈ 1.16e77; any decimal string longer than 78 digits is
    // provably >= n. n itself has 78 decimal digits.
    return -3;
  }

  // Accumulate big-endian; compare against n digit-by-digit at the end.
  uint8_t acc[32] = {0};
  for (const char *c = p; *c != '\0'; ++c) {
    if (*c < '0' || *c > '9') {
      return -4;
    }
    // acc *= 10, then acc += digit, with carry across all 32 bytes.
    uint32_t carry = (uint32_t)(*c - '0');
    for (int i = 31; i >= 0; --i) {
      uint32_t v = (uint32_t)acc[i] * 10 + carry;
      acc[i] = (uint8_t)(v & 0xff);
      carry = v >> 8;
    }
    if (carry != 0) {
      // Overflow past 32 bytes — guaranteed out of range.
      return -5;
    }
  }

  // Reject acc >= n. Compare big-endian, high byte first. The leading-
  // zero strip and the `*p != '0'` check above guarantee acc != 0 here,
  // so a range check that returns -6 on any byte > n[i] is sufficient.
  for (int i = 0; i < 32; ++i) {
    if (acc[i] < kSecp256k1N[i]) {
      break;
    }
    if (acc[i] > kSecp256k1N[i]) {
      return -6;
    }
  }

  if (out != NULL) {
    memcpy(out, acc, 32);
  }
  return 0;
}

const uint8_t *grd_compressed_G(uint8_t out[33]) {
  // Compressed encoding of G: prefix 0x02 (even Y) followed by Gx.
  static const uint8_t kCompressedG[33] = {
      0x02,
      0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62, 0x95,
      0xCE, 0x87, 0x0B, 0x07, 0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
      0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98,
  };
  if (out != NULL) {
    memcpy(out, kCompressedG, 33);
  }
  return kCompressedG;
}

static void print_hex(const uint8_t *bytes, size_t n) {
  for (size_t i = 0; i < n; ++i) {
    printf("%02x", bytes[i]);
  }
  printf("\n");
}

static int usage(void) {
  fprintf(stderr, "usage: gen_pubkey <decimal-d>\n");
  fprintf(stderr, "  d  : private scalar in [1, n-1] as a decimal string\n");
  return 64;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    return usage();
  }
  const char *dec = argv[1];

  uint8_t scalar_be[32];
  int rc = grd_parse_decimal_scalar(dec, scalar_be);
  if (rc != 0) {
    fprintf(stderr, "gen_pubkey: invalid scalar '%s' (rc=%d)\n", dec, rc);
    return 64;
  }

  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
  if (ctx == NULL) {
    fprintf(stderr, "gen_pubkey: secp256k1_context_create failed\n");
    return 70;
  }

  secp256k1_pubkey pk;
  if (!secp256k1_ec_pubkey_create(ctx, &pk, scalar_be)) {
    fprintf(stderr, "gen_pubkey: secp256k1_ec_pubkey_create failed\n");
    secp256k1_context_destroy(ctx);
    return 70;
  }

  uint8_t compressed[33];
  size_t out_len = sizeof(compressed);
  secp256k1_ec_pubkey_serialize(ctx, compressed, &out_len, &pk,
                                 SECP256K1_EC_COMPRESSED);
  if (out_len != 33) {
    fprintf(stderr, "gen_pubkey: unexpected serialize length %zu\n", out_len);
    secp256k1_context_destroy(ctx);
    return 70;
  }

  print_hex(compressed, 33);
  secp256k1_context_destroy(ctx);
  return 0;
}
