// host/checkpoint.h — atomic checkpoint (A34).
//
// Stores the current sweep position (next j, integrity hash of
// progress) so a resume can pick up exactly where the prior run
// left off. Format: small JSON file with a content hash; writes are
// atomic (write-then-rename) to survive power loss / crash.

#import <Foundation/Foundation.h>

#import "config.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * One snapshot of sweep progress.
 */
@interface GRDCheckpoint : NSObject
@property(nonatomic, readonly) GRDUInt128 next_j;
@property(nonatomic, readonly) NSString* _Nonnull targetDescriptor;
- (instancetype)initWithNextJ:(GRDUInt128)j
             targetDescriptor:(NSString* _Nonnull)target
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface GRDCheckpointStore : NSObject

- (instancetype)initWithOutputDirectory:(NSString* _Nonnull)dir
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/**
 * Atomically write @c cp to <dir>/<descriptor>.ckpt.tmp, then
 * rename to <dir>/<descriptor>.ckpt. Returns YES on success.
 */
- (BOOL)saveCheckpoint:(GRDCheckpoint* _Nonnull)cp
                 error:(NSError* _Nullable* _Nullable)error;

/**
 * Load the checkpoint for the given descriptor, or return nil if no
 * checkpoint exists (clean start).
 */
- (nullable GRDCheckpoint*)
    loadCheckpointForDescriptor:(NSString* _Nonnull)desc
                          error:(NSError* _Nullable* _Nullable)error;

@property(nonatomic, readonly) NSString* _Nonnull outputDirectory;

@end

NS_ASSUME_NONNULL_END