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

// ----------------------------------------------------------------------------
// Modes
// ----------------------------------------------------------------------------

/**
 * The two search modes greedyfind supports. Decides which kernel and which
 * target type is used.
 */
typedef NS_ENUM(NSInteger, GRDMode) {
  GRDModePubkey = 0,
  GRDModeAddress = 1,
};

// ----------------------------------------------------------------------------
// Errors
// ----------------------------------------------------------------------------

/**
 * Error domain for all greedyfind errors. See host/sweep.m for codes.
 */
extern NSString *const GRDErrorDomain;

typedef NS_ENUM(NSInteger, GRDError) {
  GRDErrorUnknown = -1,
  GRDErrorInvalidArguments = 1,
  GRDErrorMetalUnavailable = 2,
  GRDErrorLibraryLoadFailed = 3,
  GRDErrorPipelineCreationFailed = 4,
  GRDErrorBufferAllocationFailed = 5,
  GRDErrorVariantIndexBuildFailed = 6,
  GRDErrorAddressDecodeFailed = 7,
  GRDErrorCheckpointFailed = 8,
  GRDErrorCacheFailed = 9,
};

/**
 * Entry point invoked by host/main.m.
 */
int GRDRunSession(int argc, const char *_Nonnull *_Nonnull argv);

NS_ASSUME_NONNULL_END