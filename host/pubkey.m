// host/pubkey.m — variant generation + VariantIndex
// (atomic units A20, A21, A22).
//
// The 512 variants are: V = 2^i for i in [0, 255], and
// V = sum(2^j, j=0..i) = 2^(i+1) - 1 for i in [0, 255]. This
// matches `find/src/search.rs::generate_variants` in the host-side
// reference.

#import "pubkey.h"

#import "sweep.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "ecc.h"
#include <secp256k1.h>

const uint64_t kGRDVariantCount = 512;

#define GRD_VARIANT_COUNT 512

// 32-bit limbs of 2^i mod n. Pre-computed at init.
static GRDUInt256x64 grd_pow2_le[256];
// 32-bit limbs of the cumulative sum S_i = 2^(i+1) - 1 mod n.
static GRDUInt256x64 grd_cumsum_le[256];
// Human-readable label per variant (process-lifetime, never freed).
static char *grd_labels[GRD_VARIANT_COUNT];
// Fully-assembled variant table.
static GRDVariant grd_variants[GRD_VARIANT_COUNT];
static int grd_variants_inited = 0;
static pthread_once_t grd_variants_once = PTHREAD_ONCE_INIT;

static void grd_variants_init(void) {
  if (grd_variants_inited) return;

  // 2^0 mod n = 1, 2^1 mod n = 2, etc. Iterate via doubling.
  GRDUInt256x64 cur;
  cur.limbs[0] = 1; cur.limbs[1] = 0; cur.limbs[2] = 0; cur.limbs[3] = 0;
  grd_pow2_le[0] = cur;
  for (int i = 1; i < 256; ++i) {
    cur = GRDFieldAddHost(cur, cur);  // 2 * cur mod p
    grd_pow2_le[i] = cur;
  }

  // Cumulative sums: S_i = sum(2^j, j=0..i) mod p.
  GRDUInt256x64 sum;
  sum.limbs[0] = 0; sum.limbs[1] = 0; sum.limbs[2] = 0; sum.limbs[3] = 0;
  for (int i = 0; i < 256; ++i) {
    sum = GRDFieldAddHost(sum, grd_pow2_le[i]);
    grd_cumsum_le[i] = sum;
  }

  // Assemble variant table: indices 0..255 = powers of two,
  // indices 256..511 = cumulative sums.
  for (int i = 0; i < 256; ++i) {
    char label[32];
    snprintf(label, sizeof(label), "2^%d", i);
    grd_labels[i] = strdup(label);
    grd_variants[i].label = grd_labels[i];
    grd_variants[i].V = grd_pow2_le[i];
  }
  for (int i = 0; i < 256; ++i) {
    char label[48];
    snprintf(label, sizeof(label), "sum(2^0..2^%d)", i);
    grd_labels[256 + i] = strdup(label);
    grd_variants[256 + i].label = grd_labels[256 + i];
    grd_variants[256 + i].V = grd_cumsum_le[i];
  }
  grd_variants_inited = 1;
}

const GRDVariant *_Nonnull GRDGenerateVariants(size_t *_Nullable out_count) {
  pthread_once(&grd_variants_once, grd_variants_init);
  if (out_count) *out_count = GRD_VARIANT_COUNT;
  return grd_variants;
}

// ----------------------------------------------------------------------------
// compute_variant_x_bytes (A21 + A22)
// ----------------------------------------------------------------------------

// 32-byte big-endian byte order from a 4-limb little-endian
// GRDUInt256x64.
static void grd_limbs_to_be32(uint8_t out[32], GRDUInt256x64 v) {
  for (int i = 0; i < 4; ++i) {
    uint64_t limb = v.limbs[3 - i];
    for (int j = 0; j < 8; ++j) out[i * 8 + j] = (uint8_t)(limb >> ((7 - j) * 8));
  }
}

// Lazily-initialized secp256k1 context.
static secp256k1_context *grd_secp256k1_ctx(void) {
  static secp256k1_context *ctx = NULL;
  if (!ctx) ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
  return ctx;
}

// secp256k1_pubkey parsed from the standard uncompressed G serialization
// (0x04 || Gx || Gy in big-endian). Cached at first call.
static secp256k1_pubkey grd_G_pubkey(void) {
  static secp256k1_pubkey pk;
  static int inited = 0;
  if (!inited) {
    uint8_t g[65] = {
      0x04,
      0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
      0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9, 0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98,
      0x48, 0x3A, 0xDA, 0x77, 0x26, 0xA3, 0xC4, 0x65, 0x5D, 0xA4, 0xFB, 0xFC, 0x0E, 0x11, 0x08, 0xA8,
      0xFD, 0x17, 0xB4, 0x48, 0xA6, 0x85, 0x54, 0x19, 0x9C, 0x47, 0xD0, 0x8F, 0xFB, 0x10, 0xD4, 0xB8
    };
    (void)secp256k1_ec_pubkey_parse(grd_secp256k1_ctx(), &pk, g, 65);
    inited = 1;
  }
  return pk;
}

NSData *_Nullable GRDComputeVariantXBytes(
    const uint8_t *_Nonnull compressed_pubkey,
    const GRDVariant *_Nonnull variants,
    size_t variant_count,
    NSError *_Nullable *_Nullable error) {
  if (variants == NULL || variant_count == 0 || variant_count > GRD_VARIANT_COUNT) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorInvalidArguments
                                       userInfo:nil];
    return nil;
  }

  secp256k1_context *ctx = grd_secp256k1_ctx();
  secp256k1_pubkey P;
  if (!secp256k1_ec_pubkey_parse(ctx, &P, compressed_pubkey, 33)) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorInvalidArguments
                                       userInfo:nil];
    return nil;
  }
  secp256k1_pubkey G = grd_G_pubkey();

  NSMutableData *out = [NSMutableData dataWithLength:32 * variant_count];
  uint8_t *out_bytes = out.mutableBytes;

  for (size_t i = 0; i < variant_count; ++i) {
    // V_i · G: start from a copy of the generator, multiply in place.
    uint8_t v_be[32];
    grd_limbs_to_be32(v_be, variants[i].V);
    secp256k1_pubkey V_iG = G;
    if (!secp256k1_ec_pubkey_tweak_mul(ctx, &V_iG, v_be)) continue;
    // P - V·G = P + (-V·G). secp256k1 has no public point-add, but
    // ec_pubkey_negate is in-place; secp256k1_ec_pubkey_combine sums
    // two points. So: negate V_iG, then combine(P, -V_iG).
    secp256k1_ec_pubkey_negate(ctx, &V_iG);
    const secp256k1_pubkey *pks[2] = {&P, &V_iG};
    secp256k1_pubkey result;
    if (!secp256k1_ec_pubkey_combine(ctx, &result, pks, 2)) continue;
    // Serialize compressed to get x.
    uint8_t ser[33];
    size_t serlen = 33;
    secp256k1_ec_pubkey_serialize(ctx, ser, &serlen, &result,
                                  SECP256K1_EC_COMPRESSED);
    memcpy(out_bytes + i * 32, ser + 1, 32);
  }
  return out;
}