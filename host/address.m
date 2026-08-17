// host/address.m — base58check Bitcoin mainnet decoder (A23).
//
// Implements the inverse of Bitcoin's base58check encoding. Verifies
// the 4-byte double-SHA256 checksum and validates the version byte
// and payload length. For P2PKH (version 0x00) and P2SH (version 0x05)
// the payload is exactly 20 bytes (the hash160).
//
// The base58 alphabet is:
//   "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
//
// Avoiding external dependencies: we implement base58 decoding in
// pure C, and use libtomcrypt (host/hash.h) for SHA-256.

#import "address.h"

#import "sweep.h"
#import "hash.h"

#import <stdlib.h>
#import <string.h>

// Bitcoin's base58 alphabet (no 0, O, I, l to avoid visual ambiguity).
static const char *const kBase58Alphabet =
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

static int8_t kBase58Map[128];
static dispatch_once_t kBase58MapOnce;

static void grd_init_base58_map(void) {
  for (int i = 0; i < 128; ++i) kBase58Map[i] = -1;
  for (int i = 0; i < 58; ++i) {
    kBase58Map[(uint8_t)kBase58Alphabet[i]] = (int8_t)i;
  }
}

NSData *_Nullable GRDDecodeAddress(
    NSString *_Nonnull address,
    uint8_t *_Nullable out_version,
    NSError *_Nullable *_Nullable error) {
  dispatch_once(&kBase58MapOnce, ^{ grd_init_base58_map(); });

  if (address == nil || [address length] == 0) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorAddressDecodeFailed
                                       userInfo:nil];
    return nil;
  }
  const char *str = [address UTF8String];
  size_t len = strlen(str);
  if (len < 5) {  // 1 (version) + 1 (min payload) + 4 (checksum)
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorAddressDecodeFailed
                                       userInfo:nil];
    return nil;
  }

  // Convert base58 to a big-endian byte sequence. The leading '1's in
  // base58 map to 0x00 bytes; preserve their count.
  size_t zero_count = 0;
  while (str[zero_count] == '1') zero_count++;

  // Buffer for the decoded bytes (big-endian, MSB first at index 0).
  // We use a fixed 64-byte buffer and shift right when a new high byte
  // comes in, so the layout is always big-endian.
  uint8_t decoded[64];
  size_t decoded_len = 0;
  uint32_t carry = 0;
  for (size_t i = zero_count; i < len; ++i) {
    unsigned char c = (unsigned char)str[i];
    if (c >= 128 || kBase58Map[c] < 0) {
      if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                             code:GRDErrorAddressDecodeFailed
                                         userInfo:nil];
      return nil;
    }
    carry = (uint32_t)kBase58Map[c];
    // Propagate carry from LSB to MSB; prepend any final high byte.
    for (size_t j = decoded_len; j > 0; --j) {
      carry += (uint32_t)decoded[j - 1] * 58;
      decoded[j - 1] = (uint8_t)(carry & 0xFF);
      carry >>= 8;
    }
    while (carry > 0) {
      // Shift everything right by 1 byte and put carry as the new MSB.
      if (decoded_len >= sizeof(decoded)) {
        if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                               code:GRDErrorAddressDecodeFailed
                                           userInfo:nil];
        return nil;
      }
      memmove(decoded + 1, decoded, decoded_len);
      decoded[0] = (uint8_t)(carry & 0xFF);
      carry >>= 8;
      decoded_len++;
    }
  }
  if (carry > 0) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorAddressDecodeFailed
                                       userInfo:nil];
    return nil;
  }

  // Prepend leading zeros (from the leading '1's in the base58 string).
  size_t payload_total = zero_count + decoded_len;
  if (payload_total < 4) {  // need at least 4 checksum bytes
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorAddressDecodeFailed
                                       userInfo:nil];
    return nil;
  }
  uint8_t full[64];
  memset(full, 0, sizeof(full));
  memcpy(full + zero_count, decoded, decoded_len);

  // Verify the 4-byte double-SHA256 checksum at the end.
  size_t data_len = payload_total - 4;
  uint8_t expected[32];
  GRDSha256(expected, full, data_len);             // h1 = SHA256(data)
  GRDSha256(expected, expected, 32);                // h2 = SHA256(h1)
  if (memcmp(expected, full + data_len, 4) != 0) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorAddressDecodeFailed
                                       userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"Invalid base58check checksum"
                                       }];
    return nil;
  }

  // First byte is the version. Reject anything other than 0x00 (P2PKH
  // mainnet) or 0x05 (P2SH mainnet) for now.
  if (full[0] != 0x00 && full[0] != 0x05) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorAddressDecodeFailed
                                       userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"Unsupported address version byte"
                                       }];
    return nil;
  }

  // Payload length should be 20 (P2PKH / P2SH hash160).
  if (data_len - 1 != 20) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorAddressDecodeFailed
                                       userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"Unsupported payload length"
                                       }];
    return nil;
  }

  if (out_version) *out_version = full[0];
  uint8_t payload[20];
  memcpy(payload, full + 1, 20);
  return [NSData dataWithBytes:payload length:20];
}