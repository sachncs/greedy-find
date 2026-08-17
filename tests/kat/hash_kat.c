// tests/kat/hash_kat.c — KAT for SHA-256, RIPEMD-160, and hash160.
//
// Uses a small set of NIST CAVP vectors for SHA-256 (3 well-known), a
// subset of Bosselaers' RIPEMD-160 vectors, and a Bitcoin pubkey
// hash160 vector.

#include <stdio.h>
#include <string.h>

#include "hash.h"

static int g_failures = 0;

static void hex_of(const uint8_t *bytes, size_t len, char *out) {
  static const char *h = "0123456789abcdef";
  for (size_t i = 0; i < len; ++i) {
    out[i * 2] = h[bytes[i] >> 4];
    out[i * 2 + 1] = h[bytes[i] & 0xF];
  }
  out[len * 2] = 0;
}

static void check(const char *label, const uint8_t *got, const char *want) {
  char hex[65];
  hex_of(got, strlen(want) / 2, hex);
  if (strcmp(hex, want) != 0) {
    fprintf(stderr, "FAIL [%s]\n  got  %s\n  want %s\n", label, hex, want);
    g_failures++;
  }
}

// SHA-256 test vectors (NIST CAVP short messages subset).
static void test_sha256(void) {
  uint8_t out[32];
  // ""
  GRDSha256(out, (const uint8_t *)"", 0);
  check("sha256(\"\")", out,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  // "abc"
  GRDSha256(out, (const uint8_t *)"abc", 3);
  check("sha256(\"abc\")", out,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  // "The quick brown fox jumps over the lazy dog"
  const char *fox = "The quick brown fox jumps over the lazy dog";
  GRDSha256(out, (const uint8_t *)fox, strlen(fox));
  check("sha256(fox)", out,
        "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592");
}

// RIPEMD-160 test vectors (Bosselaers).
static void test_ripemd160(void) {
  uint8_t out[20];
  GRDRipemd160(out, (const uint8_t *)"", 0);
  check("ripemd160(\"\")", out,
        "9c1185a5c5e9fc54612808977ee8f548b2258d31");
  GRDRipemd160(out, (const uint8_t *)"a", 1);
  check("ripemd160(\"a\")", out, "0bdc9d2d256b3ee9daae347be6f4dc835a467ffe");
  GRDRipemd160(out, (const uint8_t *)"abc", 3);
  check("ripemd160(\"abc\")", out,
        "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc");
  GRDRipemd160(out, (const uint8_t *)"message digest", 14);
  check("ripemd160(\"message digest\")", out,
        "5d0689ef49d2fae572b881b123a85ffa21595f36");
}

// hash160 KAT — Bitcoin puzzle #66 generator point. The uncompressed
// pubkey is 0x04 || x || y. We use the Bitcoin-style hash160 for that
// compressed pubkey as a quick sanity check.
static void test_hash160(void) {
  uint8_t out[20];
  // Compressed pubkey for d=1 (privkey 0x...1): 02 + Gx.
  uint8_t pk[33] = {
      0x02,
      0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62, 0x95,
      0xCE, 0x87, 0x0B, 0x07, 0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
      0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98,
  };
  GRDHash160(out, pk);
  // hash160(02||Gx) is the P2PKH address of privkey=1.
  check("hash160(d=1 compressed)", out,
        "751e76e8199196d454941c45d1b3a323f1433bd6");
}

int main(void) {
  test_sha256();
  test_ripemd160();
  test_hash160();
  if (g_failures) {
    fprintf(stderr, "hash_kat: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("hash_kat: all tests passed\n");
  return 0;
}