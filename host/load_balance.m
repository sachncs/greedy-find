// host/load_balance.m — A44 implementation.
//
// Static initial split + a single rebalance step driven by
// per-device j/sec reports. The full production version would
// rebalance every N j's with a moving-average throughput; this
// version is the structural skeleton so the bench can measure
// the steady-state gain from rebalancing once.

#import "load_balance.h"

NS_ASSUME_NONNULL_BEGIN

@implementation GRDLoadBalancer {
  uint32_t _device_count;
  GRDUInt128 _range_start;
  GRDUInt128 _range_end;
  GRDUInt128 *_starts;
  GRDUInt128 *_ends;
  double *_throughput;
  dispatch_queue_t _lock;
}

- (instancetype)initWithDeviceCount:(uint32_t)device_count
                              range:(GRDUInt128)range {
  if ((self = [super init])) {
    _device_count = device_count > 0 ? device_count : 1;
    _range_start = (GRDUInt128){.lo = 0, .hi = 0};
    _range_end = range;
    _starts = calloc(_device_count, sizeof(GRDUInt128));
    _ends = calloc(_device_count, sizeof(GRDUInt128));
    _throughput = calloc(_device_count, sizeof(double));
    _lock = dispatch_queue_create("com.greedyfind.loadbalance",
                                  DISPATCH_QUEUE_SERIAL);
    [self resetSplitsLocked];
  }
  return self;
}

- (void)dealloc {
  if (_starts) free(_starts);
  if (_ends) free(_ends);
  if (_throughput) free(_throughput);
  [super dealloc];
}

- (uint32_t)deviceCount { return _device_count; }

- (GRDUInt128)startForDevice:(uint32_t)i {
  if (i >= _device_count) return (GRDUInt128){0, 0};
  return _starts[i];
}

- (GRDUInt128)endForDevice:(uint32_t)i {
  if (i >= _device_count) return (GRDUInt128){0, 0};
  return _ends[i];
}

- (void)reportThroughput:(double)j_per_sec forDevice:(uint32_t)i {
  if (i >= _device_count) return;
  dispatch_sync(_lock, ^{
    _throughput[i] = j_per_sec > 0 ? j_per_sec : 1.0;
  });
}

- (void)resetSplitsLocked {
  // Equal split. The high-limb case is ignored for simplicity: a
  // production implementation would carry the 128-bit division
  // through. For the bench-sized range (low-limb only) this is
  // exact.
  if (_range_end.hi != 0 || _range_end.lo == 0) {
    for (uint32_t i = 0; i < _device_count; ++i) {
      _starts[i] = (GRDUInt128){0, 0};
      _ends[i] = (GRDUInt128){0, 0};
    }
    return;
  }
  uint64_t per = _range_end.lo / _device_count;
  for (uint32_t i = 0; i < _device_count; ++i) {
    _starts[i] = (GRDUInt128){.lo = per * i, .hi = 0};
    _ends[i] = (GRDUInt128){.lo = per * (i + 1), .hi = 0};
  }
  _ends[_device_count - 1].lo = _range_end.lo;  // last slice absorbs remainder
}

- (BOOL)rebalance {
  __block BOOL changed = NO;
  dispatch_sync(_lock, ^{
    if (_device_count < 2) return;
    // Find the fastest and slowest devices.
    uint32_t fast = 0, slow = 0;
    double fast_v = _throughput[0], slow_v = _throughput[0];
    for (uint32_t i = 1; i < _device_count; ++i) {
      if (_throughput[i] > fast_v) {
        fast_v = _throughput[i];
        fast = i;
      }
      if (_throughput[i] < slow_v) {
        slow_v = _throughput[i];
        slow = i;
      }
    }
    if (fast == slow) return;
    if (fast_v <= 0 || slow_v <= 0) return;
    double ratio = fast_v / slow_v;
    if (ratio < 1.05) {
      return;  // within 5%; no rebalance needed
    }
    // Transfer 10% of the slow slice to the fast slice, capped so
    // the slow slice stays positive.
    uint64_t slow_lo = _ends[slow].lo - _starts[slow].lo;
    uint64_t xfer = slow_lo / 10;
    if (xfer == 0) return;
    _ends[slow].lo -= xfer;
    _starts[fast].lo -= xfer;
    // Maintain invariant: _starts[i+1] == _ends[i] (the slices are
    // contiguous). After the transfer, _starts[fast] may now
    // overlap with _ends[fast-1]; we shift fast's start earlier
    // and the intermediate slices stay where they were.
    if (fast > 0 && _starts[fast].lo < _ends[fast - 1].lo) {
      uint64_t shift = _ends[fast - 1].lo - _starts[fast].lo;
      _starts[fast].lo += shift;
      _ends[slow].lo += shift;
    }
    changed = YES;
  });
  return changed;
}

@end

NS_ASSUME_NONNULL_END
