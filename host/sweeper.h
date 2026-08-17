// host/sweeper.h — polymorphic Metal device sweep protocol (A30).
//
// Two concrete implementations: GRDPubkeySweeper (mode --pubkey,
// A26) and GRDAddressSweeper (mode --address, A27). The dispatcher
// in host/sweep.m picks the right one based on opts.mode.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "config.h"
#import "ecc.h"

NS_ASSUME_NONNULL_BEGIN

/** One match found by the sweeper. */
@interface GRDMatch : NSObject
@property (nonatomic, readonly) GRDUInt128 j;
@property (nonatomic, readonly) NSString *_Nonnull variant;
- (instancetype)initWithJ:(GRDUInt128)j variant:(NSString *)variant
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@protocol GRDSweeper <NSObject>

- (BOOL)setupWithOptions:(GRDOptions *)opts
                   error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(setup(options:));

- (void)executeWithCompletion:(void (^_Nonnull)(NSArray<GRDMatch *> *_Nullable,
                                                  NSError *_Nullable))completion
    NS_SWIFT_NAME(execute(completion:));

- (void)cancel;

@end

/** Base class for sweepers that need Metal setup. */
@interface GRDSweeperBase : NSObject <GRDSweeper>
@end

/** Concrete sweeper for --pubkey mode (uses grdSweepPubkey kernel). */
@interface GRDPubkeySweeper : GRDSweeperBase <GRDSweeper>
@end

/** Concrete sweeper for --address mode (uses grdSweepAddressStub). */
@interface GRDAddressSweeper : NSObject <GRDSweeper>
@end

NS_ASSUME_NONNULL_END
