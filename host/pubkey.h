// host/pubkey.h — SEC1 parser + variant generation + VariantIndex
// (filled in by atomic units A20–A22).
//
// A20 — generate_variants: produces the static 512-variant metadata
// (256 powers-of-two + 256 cumulative sums) used to seed the variant
// range. Interned at first call via a pthread_once-style init so the
// computation cost is paid once per process.
//
// A21 — compute_variant_x_bytes: per variant, computes the 32-byte
// big-endian X coordinate of (P - V·G) for a target point P. This
// mirrors the Metal kernel's per-variant work so the host KAT can
// cross-check the device output.

#import <Foundation/Foundation.h>

#import "ecc.h"

NS_ASSUME_NONNULL_BEGIN

// ----------------------------------------------------------------------------
// Variant metadata (A20)
// ----------------------------------------------------------------------------

/** Number of variants produced by generate_variants: 256 (powers of
 * two) + 256 (cumulative sums) = 512. */
extern const uint64_t kGRDVariantCount;

/** A single variant: (label, V_scalar) where V is the variant's
 * offset mod n. The label is a static string suitable for logging. */
typedef struct {
  const char *_Nonnull label;
  // Note: V is the variant offset mod n; this struct sits in a
  // process-lifetime array generated lazily on first call to
  // GRDGenerateVariants. Don't free or copy by value.
  GRDUInt256x64 V;
} GRDVariant;

/** Returns the static 512-entry variant array. Lazily initialized
 * via a pthread_once-equivalent inside this function. */
const GRDVariant *_Nonnull GRDGenerateVariants(size_t *_Nullable out_count);

// ----------------------------------------------------------------------------
// VariantIndex (A22)
// ----------------------------------------------------------------------------

/**
 * Computes the per-variant 32-byte X coordinate of (P - V·G) for a
 * compressed pubkey target P. The output is laid out as
 *   variants[variant_count][32]
 * — 32 bytes per variant, big-endian.
 *
 * The implementation reuses the host EC ops (secp256k1 for V·G and
 * field sub for P - V·G) so we have a reference path independent of
 * the Metal kernel.
 */
NSData *_Nullable GRDComputeVariantXBytes(
    const uint8_t *_Nonnull compressed_pubkey,
    const GRDVariant *_Nonnull variants,
    size_t variant_count,
    NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END