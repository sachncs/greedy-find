// host/ecc.h — secp256k1 primitives and u128 helpers.
//
// This header declares the host-side C reference implementation of
// secp256k1 field arithmetic and u128 helpers. Real implementations
// (k256-style) live in `metal/secp256k1.metal` for GPU kernels; this
// header exposes the host-side mirror so KATs can run on the CPU.

#ifndef GRD_HOST_ECC_H
#define GRD_HOST_ECC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ----------------------------------------------------------------------------
// 256-bit field element (host-side)
// ----------------------------------------------------------------------------

/** 256-bit unsigned integer in little-endian 64-bit limbs. */
typedef struct {
  uint64_t limbs[4];
} GRDUInt256x64;

// ----------------------------------------------------------------------------
// secp256k1 constants (host-side)
// ----------------------------------------------------------------------------

extern const GRDUInt256x64 GRDPrimeP;
extern const GRDUInt256x64 GRDOrderN;

// ----------------------------------------------------------------------------
// u128 helpers
// ----------------------------------------------------------------------------

typedef struct {
  uint64_t lo;
  uint64_t hi;
} GRDUInt128;

void GRDU128Add(GRDUInt128 *out, GRDUInt128 a, GRDUInt128 b);
void GRDU128Sub(GRDUInt128 *out, GRDUInt128 a, GRDUInt128 b);
int GRDU128Cmp(GRDUInt128 a, GRDUInt128 b);
bool GRDU128IsZero(GRDUInt128 a);
GRDUInt128 GRDU128FromU64(uint64_t v);

const char *GRDU128ParseDecimal(GRDUInt128 *out, const char *s);
size_t GRDU128FormatDecimal(char *buf, size_t buf_len, GRDUInt128 a);

// ----------------------------------------------------------------------------
// Host-side reference field arithmetic (mirrors metal/secp256k1.metal)
// ----------------------------------------------------------------------------

GRDUInt256x64 GRDFieldAddHost(GRDUInt256x64 a, GRDUInt256x64 b);
GRDUInt256x64 GRDFieldSubHost(GRDUInt256x64 a, GRDUInt256x64 b);
GRDUInt256x64 GRDFieldMulHost(GRDUInt256x64 a, GRDUInt256x64 b);
GRDUInt256x64 GRDFieldSqrHost(GRDUInt256x64 a);
GRDUInt256x64 GRDFieldInvHost(GRDUInt256x64 a);

bool GRDEq(GRDUInt256x64 a, GRDUInt256x64 b);
bool GRDIsZero(GRDUInt256x64 a);
bool GRDGte(GRDUInt256x64 a, GRDUInt256x64 b);

// ----------------------------------------------------------------------------
// Debug helpers
// ----------------------------------------------------------------------------

/**
 * Writes the big-endian 64-character lowercase hex representation of
 * @c a into @c out. @c out must be at least 65 bytes.
 */
void GRDU256Hex(char *out, size_t out_len, GRDUInt256x64 a);

// ----------------------------------------------------------------------------
// EC point (mirrors metal/types.metal.h::EcPoint)
// ----------------------------------------------------------------------------

typedef struct {
  GRDUInt256x64 X;
  GRDUInt256x64 Y;
  GRDUInt256x64 Z;
} GRDEcPoint;

extern const GRDEcPoint GRDSecp256k1G;

GRDEcPoint GRDEcDoubleHost(GRDEcPoint p);
GRDEcPoint GRDEcAddHost(GRDEcPoint p, GRDEcPoint q);
GRDEcPoint GRDEcAddMixedHost(GRDEcPoint p, GRDEcPoint q);
GRDEcPoint GRDEcNegHost(GRDEcPoint p);
GRDUInt256x64 GRDReduceModNHost(GRDUInt256x64 a);
GRDEcPoint GRDScalarMulHost(GRDEcPoint p, GRDUInt256x64 k);
GRDEcPoint GRDScalarMulGHost(GRDUInt256x64 k);

#ifdef __cplusplus
}
#endif

#endif  // GRD_HOST_ECC_H