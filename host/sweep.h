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

NS_ASSUME_NONNULL_END