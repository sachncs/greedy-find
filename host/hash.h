// host/hash.h — host-side SHA-256, RIPEMD-160, hash160.
//
// Mirrors metal/ecdsa.metal so KATs run on the CPU.

#ifndef GRD_HOST_HASH_H
#define GRD_HOST_HASH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** SHA-256 of @c msg (length @c len bytes), output 32 bytes big-endian. */
void GRDSha256(uint8_t out[32], const uint8_t *msg, size_t len);

/** RIPEMD-160 of @c msg (length @c len bytes), output 20 bytes big-endian. */
void GRDRipemd160(uint8_t out[20], const uint8_t *msg, size_t len);

/** hash160 = RIPEMD-160(SHA-256(compressed_pubkey)) for a 33-byte input. */
void GRDHash160(uint8_t out[20], const uint8_t *compressed_pubkey);

#ifdef __cplusplus
}
#endif

#endif  // GRD_HOST_HASH_H