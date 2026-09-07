// metal/types.metal — secp256k1 types and constants.
//
// All numeric types are little-endian 4-limb 256-bit fields unless
// explicitly noted otherwise. The 4-limb layout matches k256's
// `crypto-bigint::U256`, so host code using `__uint128_t` limbs lines up
// with GPU arithmetic limb-for-limb. This simplifies differential testing
// against `find`.

#ifndef GRD_TYPES_H
#define GRD_TYPES_H

#include <metal_stdlib>
using namespace metal;

// ----------------------------------------------------------------------------
// Field element (secp256k1 prime field Fp)
// ----------------------------------------------------------------------------

/**
 * A 256-bit unsigned integer in little-endian 32-bit limb order. Used
 * for both secp256k1 field elements (mod p) and scalars (mod n). Layout
 * matches k256's `U256` so cross-implementation diffs are trivial.
 */
struct UInt256 {
  uint32_t limbs[8];  // little-endian; limbs[0] is least significant
};

/**
 * 256-bit unsigned integer in 64-bit limb order. Used in hot field
 * arithmetic; half as many limbs to step through as UInt256.
 */
struct UInt256x64 {
  uint64_t limbs[4];  // little-endian; limbs[0] is least significant
};

// ----------------------------------------------------------------------------
// Elliptic curve point
// ----------------------------------------------------------------------------

/**
 * A point on the secp256k1 curve in Jacobian projective coordinates
 * (X, Y, Z) where affine = (X/Z^2, Y/Z^3). Z = 1 for affine points.
 *
 * 3 * 4 limbs * 8 bytes = 96 bytes total. Natural 16-byte alignment.
 */
struct EcPoint {
  UInt256x64 X;
  UInt256x64 Y;
  UInt256x64 Z;
};

// ----------------------------------------------------------------------------
// Scalar
// ----------------------------------------------------------------------------

/** A 256-bit unsigned scalar value (j, V, d, etc.). */
typedef UInt256x64 EcScalar;

// ----------------------------------------------------------------------------
// Variant set + sweep tuning constants
// ----------------------------------------------------------------------------

/** Maximum number of variants (powers-of-two + cumulative sums). */
constant uint kMaxVariantCount = 512;

/** Number of threads in a sweep threadgroup. */
__attribute__((unused)) constant uint kThreadsPerThreadgroup = 32;

/** Bytes per variant X-coordinate (32-byte big-endian compressed X). */
constant uint kVariantXBytes = 32;

/** Bytes per threadgroup-resident variant index (512 * 32 = 16 KiB). */
__attribute__((unused)) constant uint kVariantIndexBytes =
    kMaxVariantCount * kVariantXBytes;

/** 512-bit productivity bitmap fits in 16 uint32 words. */
__attribute__((unused)) constant uint kVariantBitmapWords =
    kMaxVariantCount / 32;

// ----------------------------------------------------------------------------
// secp256k1 curve parameters (constant address space)
//
// Note: MSL requires program-scope variables to be in the `constant`
// address space. The macros below construct a single UInt256x64 / EcPoint
// from explicit 64-bit hex literals.
// ----------------------------------------------------------------------------

/**
 * secp256k1 prime p = 2^256 - 2^32 - 977.
 *   p = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
 */
#define GRD_P0 0xFFFFFFFEFFFFFC2Ful
#define GRD_P1 0xFFFFFFFFFFFFFFFFul
#define GRD_P2 0xFFFFFFFFFFFFFFFFul
#define GRD_P3 0xFFFFFFFFFFFFFFFFul

/**
 * secp256k1 curve order n.
 *   n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
 */
#define GRD_N0 0xBFD25E8CD0364141ul
#define GRD_N1 0xBAAEDCE6AF48A03Bul
#define GRD_N2 0xFFFFFFFFFFFFFFFEul
#define GRD_N3 0xFFFFFFFFFFFFFFFFul

/**
 * secp256k1 curve coefficient b = 7 (a = 0).
 */
#define GRD_B0 7ul
#define GRD_B1 0ul
#define GRD_B2 0ul
#define GRD_B3 0ul

/**
 * Generator Gx:
 *   0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
 */
#define GRD_GX0 0x59F2815B16F81798ul
#define GRD_GX1 0x029BFCDB2DCE28D9ul
#define GRD_GX2 0x55A06295CE870B07ul
#define GRD_GX3 0x79BE667EF9DCBBACul

/**
 * Generator Gy:
 *   0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
 */
#define GRD_GY0 0x9C47D08FFB10D4B8ul
#define GRD_GY1 0xFD17B448A6855419ul
#define GRD_GY2 0x5DA4FBFC0E1108A8ul
#define GRD_GY3 0x483ADA7726A3C465ul

// Identity = (0, 0, 0).
#define GRD_ID_X0 0ul
#define GRD_ID_X1 0ul
#define GRD_ID_X2 0ul
#define GRD_ID_X3 0ul
#define GRD_ID_Y0 0ul
#define GRD_ID_Y1 0ul
#define GRD_ID_Y2 0ul
#define GRD_ID_Y3 0ul
#define GRD_ID_Z0 0ul
#define GRD_ID_Z1 0ul
#define GRD_ID_Z2 0ul
#define GRD_ID_Z3 0ul

// ----------------------------------------------------------------------------
// Convenience constructors
// ----------------------------------------------------------------------------

/** Returns a UInt256x64 from 4 hex literals. */
inline UInt256x64 grdMakeU256(uint64_t l0, uint64_t l1, uint64_t l2,
                              uint64_t l3) {
  return {{l0, l1, l2, l3}};
}

/** Returns the secp256k1 prime p as a UInt256x64. */
inline UInt256x64 grdPrimeP() {
  return {{GRD_P0, GRD_P1, GRD_P2, GRD_P3}};
}

/** Returns the secp256k1 curve order n as a UInt256x64. */
inline UInt256x64 grdOrderN() {
  return {{GRD_N0, GRD_N1, GRD_N2, GRD_N3}};
}

/** Returns the generator point G in affine coordinates. */
inline EcPoint grdGenerator() {
  EcPoint p;
  p.X = {{GRD_GX0, GRD_GX1, GRD_GX2, GRD_GX3}};
  p.Y = {{GRD_GY0, GRD_GY1, GRD_GY2, GRD_GY3}};
  p.Z = {{1ul, 0ul, 0ul, 0ul}};
  return p;
}

/** Returns the identity element (point at infinity). */
inline EcPoint grdIdentity() {
  EcPoint p;
  p.X = {{0ul, 0ul, 0ul, 0ul}};
  p.Y = {{0ul, 0ul, 0ul, 0ul}};
  p.Z = {{0ul, 0ul, 0ul, 0ul}};
  return p;
}

/**
 * Returns true if @c p is the identity element. Identity is encoded as
 * Z = 0 (per `find/src/ecc.rs::PROJECTIVE_IDENTITY`); this is the
 * convention used throughout greedyfind.
 */
inline bool grdIsIdentity(EcPoint p) {
  return p.Z.limbs[0] == 0ul && p.Z.limbs[1] == 0ul && p.Z.limbs[2] == 0ul
         && p.Z.limbs[3] == 0ul;
}

#endif  // GRD_TYPES_H