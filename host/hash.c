// host/hash.c — Host-side reference using libtomcrypt.
//
// SHA-256 and RIPEMD-160 are thin wrappers around libtomcrypt
// (installed via Homebrew). The Metal kernel keeps its own
// from-scratch implementation since GPU kernels cannot link C libraries.

#include "hash.h"

#include <string.h>

#include <tomcrypt.h>

// libtomcrypt's hash_descriptor table is empty until the consumer
// registers the hashes. On this build, `register_hash(&rmd160_desc)`
// returns CRYPT_ERROR (1) for reasons we couldn't pin down — possibly
// a build-config mismatch. The rmd160 / sha256 init / process / done
// entry points are exported and work directly, so we just call those
// without going through the descriptor table.

void GRDSha256(uint8_t out[32], const uint8_t *msg, size_t len) {
  hash_state st;
  if (sha256_init(&st) != CRYPT_OK) {
    memset(out, 0, 32);
    return;
  }
  if (sha256_process(&st, msg, len) != CRYPT_OK) {
    memset(out, 0, 32);
    return;
  }
  sha256_done(&st, out);
}

void GRDRipemd160(uint8_t out[20], const uint8_t *msg, size_t len) {
  hash_state st;
  if (rmd160_init(&st) != CRYPT_OK) {
    memset(out, 0, 20);
    return;
  }
  if (rmd160_process(&st, msg, len) != CRYPT_OK) {
    memset(out, 0, 20);
    return;
  }
  rmd160_done(&st, out);
}

void GRDHash160(uint8_t out[20], const uint8_t *compressed_pubkey) {
  uint8_t sha_out[32];
  GRDSha256(sha_out, compressed_pubkey, 33);
  GRDRipemd160(out, sha_out, 32);
}