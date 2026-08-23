#ifndef GRD_TOOLS_GEN_PUBKEY_H
#define GRD_TOOLS_GEN_PUBKEY_H

#include <stdint.h>
#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Parses a decimal unsigned integer into a 32-byte big-endian scalar.
 *
 * @param dec    Null-terminated decimal string. Must be non-empty, all digits,
 *               and represent a value strictly less than the secp256k1 group
 *               order n.
 * @param out    Output buffer; receives 32 bytes of big-endian scalar data on
 *               success. May be NULL if the caller only wants to validate.
 * @return 0 on success; non-zero on parse failure or out-of-range.
 */
int grd_parse_decimal_scalar(const char *dec, uint8_t out[32]);

/**
 * Returns the compressed SEC1 encoding of the secp256k1 generator point
 * G = (Gx, Gy). 33 bytes: 0x02/0x03 prefix followed by the 32-byte big-endian
 * X coordinate.
 */
const uint8_t *grd_compressed_G(uint8_t out[33]);

#ifdef __cplusplus
}
#endif

#endif  /* GRD_TOOLS_GEN_PUBKEY_H */
