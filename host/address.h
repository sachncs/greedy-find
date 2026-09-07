// host/address.h — base58check P2PKH mainnet decoder (A23).
//
// Given a base58-encoded mainnet P2PKH address (starts with '1' on
// mainnet), decode it to the 20-byte payload (the hash160 of the
// recipient's compressed pubkey). Returns nil + error on invalid
// checksum, wrong version byte, or wrong length.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Result of a successful base58check decode.
 *
 * `version` is the address version byte (0x00 for P2PKH mainnet,
 * 0x05 for P2SH mainnet). `payload` is the 20-byte hash160 of the
 * recipient script (P2PKH) or script (P2SH).
 */
typedef struct {
  uint8_t version;
  uint8_t payload[20];
} GRDAddress;

/**
 * Decode a base58check Bitcoin mainnet address string.
 *
 * Returns the version + payload on success, or nil + error on
 * invalid base58, wrong checksum, unsupported version, or wrong
 * payload length.
 */
NSData *_Nullable GRDDecodeAddress(
    NSString *_Nonnull address,
    uint8_t *_Nullable out_version,
    NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END