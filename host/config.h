// host/config.h — session configuration + argument parsing (A28).
//
// Defines the parsed-arguments structure used by the host-side
// dispatcher, plus the error codes returned by GRDRunSession.

#import <Foundation/Foundation.h>

#import "ecc.h"

NS_ASSUME_NONNULL_BEGIN

// ----------------------------------------------------------------------------
// Mode
// ----------------------------------------------------------------------------

/** Which target the user supplied. Mutually exclusive. */
typedef NS_ENUM(NSInteger, GRDMode) {
  GRDModePubkey = 0,    // --pubkey <hex>
  GRDModeAddress = 1,   // --address <base58>
};

/** Source of the target. The dispatcher uses this to pick the
 * device-side kernel. */
typedef NS_ENUM(NSInteger, GRDTargetKind) {
  GRDTargetKindNone = 0,        // error
  GRDTargetKindPubkey = 1,      // 33-byte compressed pubkey
  GRDTargetKindAddress = 2,     // 20-byte hash160 (P2PKH or P2SH)
};

/** Resolved target: the X-coordinate (32 bytes little-endian limbs
 * for the device kernel) plus the original 33-byte compressed pubkey
 * for --pubkey mode. */
typedef struct {
  GRDTargetKind kind;
  GRDUInt256x64 target_x;  // little-endian 4 × 64-bit limbs (secp256k1)
  union {
    uint8_t pubkey[33];    // compressed pubkey (kind == Pubkey)
    uint8_t hash160[20];   // 20-byte hash160 (kind == Address)
  };
} GRDTarget;

// ----------------------------------------------------------------------------
// Parsed options
// ----------------------------------------------------------------------------

/** All CLI options parsed into a struct, ready for the dispatcher. */
typedef struct {
  GRDMode mode;
  GRDTarget target;
  GRDUInt128 from;
  GRDUInt128 to;
  uint32_t batch_size;        // default 32
  uint32_t variants;          // 256 or 512, default 512
  uint32_t anchor_interval_k; // anchors every 2^k threadgroups, default 16
  int32_t gpu_index;          // -1 = all, >=0 = specific device
  bool cache_points;
  bool resume;
  const char *_Nullable output_dir;   // default ./greedyfind-out
  const char *_Nullable log_dir;      // default ./greedyfind-out
} GRDOptions;

// ----------------------------------------------------------------------------
// Argument parsing
// ----------------------------------------------------------------------------

/** Parse argv into a populated GRDOptions. The returned object must
 * be released via GRDOptionsFree. On error, *outError is set and
 * NULL is returned. */
GRDOptions *_Nullable GRDOptionsFromArgv(
    int argc, const char *_Nonnull *_Nonnull argv,
    NSError *_Nullable *_Nullable outError);

/** Release the resources owned by a GRDOptions. */
void GRDOptionsFree(GRDOptions *_Nullable opts);

// ----------------------------------------------------------------------------
// Errors (shared with host/sweep.h)
// ----------------------------------------------------------------------------

// Error codes are declared in host/sweep.h. Forward-declare here
// so callers can include just config.h for argument parsing without
// pulling in the full sweep surface.
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
  GRDErrorGPUNotImplemented = 10,
};

NS_ASSUME_NONNULL_END