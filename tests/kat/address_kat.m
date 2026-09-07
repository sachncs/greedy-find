// tests/kat/address_kat.c — KAT for base58check P2PKH/P2SH address
// decoding. Tests against known Bitcoin addresses and their hash160
// payloads.

#import <Foundation/Foundation.h>

#import <stdio.h>
#import <string.h>

#import "address.h"
#import "ecc.h"

static int g_failures = 0;

static void check_decoded(const char *address, const char *expected_hash160_hex,
                         uint8_t expected_version) {
  uint8_t version = 0;
  NSError *err = nil;
  NSData *payload = GRDDecodeAddress([NSString stringWithUTF8String:address],
                                    &version, &err);
  if (payload == nil) {
    fprintf(stderr, "FAIL [%s] decode failed: %s\n", address,
            err ? [[err localizedDescription] UTF8String] : "(no error)");
    g_failures++;
    return;
  }
  if (version != expected_version) {
    fprintf(stderr, "FAIL [%s] version: got 0x%02x, want 0x%02x\n", address,
            version, expected_version);
    g_failures++;
  }
  if ([payload length] != 20) {
    fprintf(stderr, "FAIL [%s] payload length: %lu, want 20\n", address,
            (unsigned long)[payload length]);
    g_failures++;
    return;
  }
  // Compare bytes to expected hex string.
  const char *p = expected_hash160_hex;
  const uint8_t *bytes = [payload bytes];
  for (size_t i = 0; i < 20; ++i) {
    unsigned int byte;
    if (sscanf(p, "%2x", &byte) != 1 || (uint8_t)byte != bytes[i]) {
      fprintf(stderr, "FAIL [%s] byte %zu: got 0x%02x, want 0x%02x\n",
              address, i, bytes[i], byte);
      g_failures++;
      return;
    }
    p += 2;
  }
}

// Test vectors from Bitcoin core test fixtures + Bitcoin wiki.
static void test_known_addresses(void) {
  // 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa — Bitcoin genesis pubkey
  // (Satoshi's well-known address). P2PKH, version 0x00, hash160 of
  // the compressed pubkey:
  //   62e907b15cbf27d5425399ebf6f0fb50ebb88f18.
  check_decoded("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
                "62e907b15cbf27d5425399ebf6f0fb50ebb88f18", 0x00);

  // 3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy — P2SH, version 0x05.
  // P2SH script hash is also 20 bytes (hash160 of the script).
  check_decoded("3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy",
                "b472a266d0bd89c13706a4132ccfb16f7c3b9fcb", 0x05);
}

static void test_invalid_addresses(void) {
  // Empty string.
  NSData *p = GRDDecodeAddress(@"", NULL, NULL);
  if (p != nil) {
    fprintf(stderr, "FAIL [] should fail but got data\n");
    g_failures++;
  }
  // Bad character.
  p = GRDDecodeAddress(@"1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfN!", NULL, NULL);
  if (p != nil) {
    fprintf(stderr, "FAIL [1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfN!] should fail\n");
    g_failures++;
  }
  // Too short.
  p = GRDDecodeAddress(@"1abc", NULL, NULL);
  if (p != nil) {
    fprintf(stderr, "FAIL [1abc] should fail (too short)\n");
    g_failures++;
  }
  // Bad checksum (one character flipped in a real address).
  p = GRDDecodeAddress(@"1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb", NULL, NULL);
  if (p != nil) {
    fprintf(stderr, "FAIL [1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb] should fail (bad checksum)\n");
    g_failures++;
  }
}

int main(void) {
  @autoreleasepool {
    test_known_addresses();
    test_invalid_addresses();
  }
  if (g_failures) {
    fprintf(stderr, "address_kat: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("address_kat: all tests passed\n");
  return 0;
}