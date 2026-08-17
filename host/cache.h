// host/cache.h — find byte-compatible on-disk X-coord cache (A33).
//
// Caches the 32-byte big-endian X coordinate for every (variant_index,
// anchor_index) pair so the host doesn't have to recompute them on
// resume. Format is the same as the find crate's cache format: a
// single binary file per (pubkey, range) pair, with the file name
// derived from a deterministic hash of the target X + [from, to).
//
// Each entry is 32 bytes (the X coordinate). The variant × anchor
// matrix is laid out row-major: variant_index * num_anchors + anchor_index.

#import <Foundation/Foundation.h>

#import "config.h"
#import "ecc.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Read-only or read-write cache for a single (pubkey, range) pair.
 * Threadsafe via an internal dispatch queue.
 */
@interface GRDCache : NSObject

/** Build a cache for the given target X and [from, to) range. */
- (instancetype)initWithTargetX:(GRDUInt256x64)target_x
                           from:(GRDUInt128)from
                             to:(GRDUInt128)to
                outputDirectory:(NSString* _Nonnull)dir
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/** Write the X coordinate for the (variant, anchor) pair. */
- (BOOL)setX:(const uint8_t* _Nonnull)x_bytes
    forVariant:(uint32_t)variant
        anchor:(uint64_t)anchor
         error:(NSError* _Nullable* _Nullable)error;

/** Read the X coordinate; returns nil if not yet cached. */
- (nullable NSData*)xForVariant:(uint32_t)variant
                         anchor:(uint64_t)anchor
                          error:(NSError* _Nullable* _Nullable)error;

/** Flush any pending writes to disk. */
- (BOOL)sync:(NSError* _Nullable* _Nullable)error;

/** Mark cache as complete; rejects further writes. */
- (void)close;

@property(nonatomic, readonly) NSString* _Nonnull filePath;
@property(nonatomic, readonly) NSString* _Nonnull targetDescriptor;

@end

NS_ASSUME_NONNULL_END