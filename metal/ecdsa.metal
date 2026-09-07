// metal/ecdsa.metal — SHA-256, RIPEMD-160, and hash160.
//
// SHA-256 is a clean port of the FIPS 180-4 reference algorithm.
// RIPEMD-160 and hash160 are stubs pending a clean port of the
// libtomcrypt/openssl reference; the host C reference implementation
// uses libtomcrypt for these primitives, and the Metal kernel
// currently doesn't use RIPEMD-160/hash160 (the variant-index sweep
// kernel works on X-coordinates only).

#include <metal_stdlib>
#include "types.metal.h"
using namespace metal;

// ----------------------------------------------------------------------------
// SHA-256 (FIPS 180-4)
// ----------------------------------------------------------------------------

constant uint32_t kSha256K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

inline uint32_t grdSha256Ror(uint32_t x, uint k) {
  return (x >> k) | (x << (32u - k));
}

inline void grdSha256Compress(uint h[8], const uint8_t block[64]) {
  uint32_t w[64];
  for (uint i = 0; i < 16; ++i) {
    w[i] = (uint32_t(block[i * 4]) << 24) | (uint32_t(block[i * 4 + 1]) << 16) |
           (uint32_t(block[i * 4 + 2]) << 8) | uint32_t(block[i * 4 + 3]);
  }
  for (uint i = 16; i < 64; ++i) {
    uint32_t s0 = grdSha256Ror(w[i - 15], 7) ^ grdSha256Ror(w[i - 15], 18) ^
                  (w[i - 15] >> 3);
    uint32_t s1 = grdSha256Ror(w[i - 2], 17) ^ grdSha256Ror(w[i - 2], 19) ^
                  (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6],
      hh = h[7];
  for (uint i = 0; i < 64; ++i) {
    uint32_t S1 = grdSha256Ror(e, 6) ^ grdSha256Ror(e, 11) ^ grdSha256Ror(e, 25);
    uint32_t ch = (e & f) ^ (~e & g);
    uint32_t t1 = hh + S1 + ch + kSha256K[i] + w[i];
    uint32_t S0 = grdSha256Ror(a, 2) ^ grdSha256Ror(a, 13) ^ grdSha256Ror(a, 22);
    uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
    uint32_t t2 = S0 + mj;
    hh = g; g = f; f = e; e = d + t1;
    d = c; c = b; b = a; a = t1 + t2;
  }
  h[0] += a; h[1] += b; h[2] += c; h[3] += d;
  h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

/**
 * SHA-256 of a message up to 55 bytes (single block). Result as 32
 * big-endian bytes in @c out. The input must be a device pointer.
 */
inline void grdSha256(uint8_t out[32], const device uint8_t *msg, uint len) {
  uint h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
              0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

  uint8_t block[64] = {0};
  for (uint i = 0; i < len; ++i) block[i] = msg[i];
  block[len] = 0x80;
  uint64_t bitlen = uint64_t(len) * 8ull;
  for (uint i = 0; i < 8; ++i) {
    block[63 - i] = uint8_t(bitlen >> (i * 8));
  }
  grdSha256Compress(h, block);

  for (uint i = 0; i < 8; ++i) {
    out[i * 4 + 0] = uint8_t(h[i] >> 24);
    out[i * 4 + 1] = uint8_t(h[i] >> 16);
    out[i * 4 + 2] = uint8_t(h[i] >> 8);
    out[i * 4 + 3] = uint8_t(h[i]);
  }
}

// ----------------------------------------------------------------------------
// RIPEMD-160 + hash160 are pending a clean port of the libtomcrypt
// reference. The host C path uses libtomcrypt (see host/hash.c).
// For the Metal kernel, A24-A28 do not require RIPEMD-160 or hash160
// (the variant-index sweep kernel works on X-coordinates only). When
// A26 --address mode needs hash160, port the libtomcrypt C source
// (src/hashes/rmd160.c) directly to MSL.
// ----------------------------------------------------------------------------