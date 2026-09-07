// host/load_balance.h — dynamic load rebalancing (A44).
//
// Per-device throughput monitoring and j-range rebalancing. The
// host enqueues a [from, to) sweep across N devices (one range
// slice per device). On every rebalance tick each device reports
// its j/sec; the slowest device loses some range, the fastest
// gains it, and the new split is handed back to the dispatchers.
//
// Measured-revert rule: keep iff the multi-GPU host path
// (--gpu all) shows a total throughput within 5% of
// N * single-GPU throughput at any device count >= 2. If
// rebalancing hurts, this file is removed and the host stays on
// the static-split path.

#import <Foundation/Foundation.h>

#import "config.h"
#import "ecc.h"

NS_ASSUME_NONNULL_BEGIN

@interface GRDLoadBalancer : NSObject

- (instancetype)initWithDeviceCount:(uint32_t)device_count
                              range:(GRDUInt128)range
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Number of devices being balanced. */
@property (nonatomic, readonly) uint32_t deviceCount;

/** Current per-device j-ranges. Slice @c i covers [start[i], end[i]). */
- (GRDUInt128)startForDevice:(uint32_t)i;
- (GRDUInt128)endForDevice:(uint32_t)i;

/** Report measured throughput for device @c i (j/sec). */
- (void)reportThroughput:(double)j_per_sec forDevice:(uint32_t)i;

/** Recompute the per-device split from the latest throughputs and
 *  return YES iff the split changed. */
- (BOOL)rebalance;

@end

NS_ASSUME_NONNULL_END
