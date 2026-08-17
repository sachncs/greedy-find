// host/sweep.h — public surface of the host-side dispatcher.
//
// The sweep module owns the lifecycle of a Metal-accelerated search
// session: device enumeration, command-queue setup, kernel dispatch,
// and result recovery. The polymorphic GRDSweeper protocol is declared
// here along with the two concrete implementations.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "config.h"
#import "pubkey.h"
#import "address.h"
#import "ecc.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Entry point invoked by host/main.m.
 *
 * Returns the process exit code (0 = success, non-zero = failure with
 * a message written to stderr).
 */
int GRDRunSession(int argc, const char *_Nonnull *_Nonnull argv);

/**
 * CPU pubkey sweep over [from, to) using libsecp256k1. Used by the
 * bench harness (bench/sweep_bench.m) as a real, measured baseline
 * when the Metal runtime cannot create compute pipelines
 * (XPC_ERROR_CONNECTION_INTERRUPTED in sandboxed environments).
 *
 * For each j in [from, to), compute j*G via secp256k1_pubkey_tweak_mul
 * and compare its X to @c target_x (32 bytes big-endian). Records
 * the match count to @c out_match_count. Returns the wall-clock
 * elapsed time in seconds, or -1 on error.
 */
double GRDRunPubkeySweepCPU(
    const uint8_t *_Nonnull target_x,
    GRDUInt128 from,
    GRDUInt128 to,
    uint32_t *_Nullable out_match_count);

NS_ASSUME_NONNULL_END