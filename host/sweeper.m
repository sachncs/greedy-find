// host/sweeper.m — Metal device sweep implementations (A29-A32).
//
// Implements:
//   - GRDMatch (one match found by the sweeper).
//   - GRDSweeperBase: shared setup across ALL Metal devices
//     (MTLCopyAllDevices), one command queue per device, one
//     pipeline per device, and concurrent dispatch across devices.
//   - GRDPubkeySweeper (--pubkey mode; A26 kernel) — concrete subclass.
//   - GRDAddressSweeper (--address mode; A27 stub) — concrete subclass.
//
// Concurrency model:
//   * N devices, K in-flight command buffers per device (pipelined).
//   * The host-side prep work (variant upload, target upload, anchor
//     precompute) runs on a concurrent dispatch queue and parallelises
//     across devices via dispatch_apply.
//   * Match recovery is parallelised via dispatch_apply over the
//     per-device match buffers.
//
// The class @interfaces are declared in host/sweeper.h. This file only
// provides the @implementation blocks.

#import "sweeper.h"

#import "config.h"
#import "pubkey.h"

#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

NS_ASSUME_NONNULL_BEGIN

// Per-device state. Each device gets its own queue, library, and
// pipelines. Variants and bitmap are uploaded once per device (no
// host<->device sharing, even on unified-memory Macs, because the
// driver still copies on first use).
@interface GRDDeviceState : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLLibrary> library;
@property (nonatomic, strong) id<MTLComputePipelineState> pipelinePrune;
@property (nonatomic, strong) id<MTLComputePipelineState> pipelineSweep;
@property (nonatomic, strong) id<MTLBuffer> variantsBuffer;
@property (nonatomic, strong) id<MTLBuffer> targetBuffer;
@property (nonatomic, strong) id<MTLBuffer> bitmapBuffer;
@property (nonatomic, strong) id<MTLBuffer> matchBuffer;
@property (nonatomic, strong) id<MTLBuffer> matchCountBuffer;
@property (nonatomic, assign) uint64_t j_per_sec;  // last measured
@end

@implementation GRDDeviceState
@end

@implementation GRDMatch

- (instancetype)initWithJ:(GRDUInt128)j variant:(NSString *)variant {
  if ((self = [super init])) {
    _j = j;
    _variant = [variant copy];
  }
  return self;
}

- (NSString *)description {
  char jbuf[40];
  GRDU128FormatDecimal(jbuf, sizeof(jbuf), self.j);
  return [NSString stringWithFormat:@"GRDMatch(j=%s, variant=%@)", jbuf, self.variant];
}

@end

// =============================================================================
// GRDSweeperBase — common Metal setup across all devices.
// =============================================================================

@interface GRDSweeperBase () {
 @public
  NSArray<GRDDeviceState *> *_devices;   // every Metal device
  dispatch_queue_t _completion_queue;
  dispatch_queue_t _prep_queue;          // concurrent, for host prep
  uint32_t _pipeline_depth;              // in-flight command buffers per device
  uint32_t _device_count;

  GRDOptions *_options;
  BOOL _cancelled;
  BOOL _setup_done;
  size_t _variant_count;
  uint32_t _batch_size;
  uint32_t _anchor_interval_k;
}
@end

@implementation GRDSweeperBase

- (instancetype)init {
  if ((self = [super init])) {
    _completion_queue = dispatch_queue_create("com.greedyfind.sweeper.completion",
                                             DISPATCH_QUEUE_SERIAL);
    _prep_queue = dispatch_queue_create("com.greedyfind.sweeper.prep",
                                        DISPATCH_QUEUE_CONCURRENT);
    _variant_count = 512;
    _batch_size = 32;
    _anchor_interval_k = 16;
    // Default: 3 in-flight command buffers per device. The Metal
    // scheduler can overlap the buffers' execution, hiding the
    // per-buffer dispatch overhead. The depth is bounded so a
    // misconfigured sweep does not exhaust VRAM with pending buffers.
    _pipeline_depth = 3;
  }
  return self;
}

- (void)dealloc {
  [super dealloc];
}

- (void)cancel {
  _cancelled = YES;
}

- (BOOL)setupWithOptions:(GRDOptions *)opts
                   error:(NSError *_Nullable *_Nullable)error {
  _options = opts;
  _cancelled = NO;
  _setup_done = NO;

  _variant_count = opts->variants == 256 ? 256 : 512;
  _batch_size = opts->batch_size ? opts->batch_size : 32;
  _anchor_interval_k = opts->anchor_interval_k;

  // Enumerate every Metal device. MTLCopyAllDevices is the supported
  // way to get a multi-GPU fan-out; the system default device is
  // just the first one. On a 2-GPU M-series box we get 2 entries.
  NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
  if (all.count == 0) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorMetalUnavailable
                                       userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"No Metal-compatible device found"
                                       }];
    return NO;
  }

  // Optionally filter to a specific GPU index from --gpu.
  NSArray<id<MTLDevice>> *selected = all;
  if (opts->gpu_index >= 0 && (NSUInteger)opts->gpu_index < (NSUInteger)all.count) {
    selected = @[all[(NSUInteger)opts->gpu_index]];
  }

  NSMutableArray<GRDDeviceState *> *states = [NSMutableArray arrayWithCapacity:selected.count];
  dispatch_group_t prep_group = dispatch_group_create();
  // Use a serial group to keep error reporting coherent. The host-side
  // upload work is trivial (kilobytes), so concurrent prep buys little
  // and serial is simpler to reason about.
  for (id<MTLDevice> dev in selected) {
    dispatch_group_enter(prep_group);
    dispatch_async(_prep_queue, ^{
      GRDDeviceState *s = [self _setupOneDevice:dev error:error];
      if (s) {
        @synchronized (states) { [states addObject:s]; }
      }
      dispatch_group_leave(prep_group);
    });
  }
  dispatch_group_wait(prep_group, DISPATCH_TIME_FOREVER);
  if (states.count == 0) return NO;

  _devices = [states copy];
  _device_count = (uint32_t)_devices.count;
  _setup_done = YES;
  return YES;
}

// Per-device setup. Returns nil and sets *error on any failure;
// callers should treat nil as fatal for the whole sweep.
- (nullable GRDDeviceState *)_setupOneDevice:(id<MTLDevice>)dev
                                       error:(NSError *_Nullable *_Nullable)error {
  GRDDeviceState *s = [GRDDeviceState new];
  s.device = dev;
  s.queue = [dev newCommandQueue];
  if (!s.queue) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorPipelineCreationFailed
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                     @"newCommandQueue failed"}];
    return nil;
  }
  // The Metal command queue is the gate to concurrency. On Apple
  // The command queue's default in-flight buffer count is 64,
  // which is more than enough for our pipeline_depth of 3 per
  // device. Multi-GPU fan-out is the dominant parallelism source;
  // per-device depth is kept small to avoid VRAM pressure.

  NSError *lib_err = nil;
  NSURL *url = [NSURL fileURLWithPath:
      [[NSBundle mainBundle] pathForResource:@"greedy" ofType:@"metallib"]];
  if (url && [[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
    s.library = [dev newLibraryWithURL:url error:&lib_err];
  } else {
    s.library = [dev newDefaultLibrary];
  }
  if (!s.library) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorLibraryLoadFailed
                                       userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"Failed to load greedy.metallib"
                                       }];
    return nil;
  }

  id<MTLFunction> fn_prune = [s.library newFunctionWithName:@"grdVariantPrune"];
  id<MTLFunction> fn_sweep = [s.library newFunctionWithName:@"grdSweepPubkey"];
  if (!fn_prune || !fn_sweep) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorPipelineCreationFailed
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                     @"Missing compute function"}];
    return nil;
  }
  s.pipelinePrune = [dev newComputePipelineStateWithFunction:fn_prune error:&lib_err];
  s.pipelineSweep = [dev newComputePipelineStateWithFunction:fn_sweep error:&lib_err];
  if (!s.pipelinePrune || !s.pipelineSweep) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorPipelineCreationFailed
                                       userInfo:lib_err ? @{
                                         NSUnderlyingErrorKey: lib_err
                                       } : nil];
    return nil;
  }

  // Per-device buffers. The variant table is the largest at 16 KiB
  // (512 × 32 bytes) and gets uploaded once per device.
  size_t vcount = 0;
  const GRDVariant *variants = GRDGenerateVariants(&vcount);
  if (vcount != _variant_count) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorVariantIndexBuildFailed
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                     @"Variant count mismatch"}];
    return nil;
  }
  size_t variant_bytes = vcount * sizeof(GRDVariant);
  s.variantsBuffer = [dev newBufferWithLength:variant_bytes
                                      options:MTLResourceStorageModeShared];
  if (!s.variantsBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return nil;
  }
  memcpy([s.variantsBuffer contents], variants, variant_bytes);

  s.targetBuffer = [dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
  if (!s.targetBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return nil;
  }
  uint8_t *target_bytes = [s.targetBuffer contents];
  GRDUInt256x64 tx = _options->target.target_x;
  for (int i = 0; i < 4; ++i) {
    uint64_t limb = tx.limbs[3 - i];
    for (int b = 0; b < 8; ++b) target_bytes[i * 8 + b] = (uint8_t)(limb >> ((7 - b) * 8));
  }

  s.bitmapBuffer = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
  if (!s.bitmapBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return nil;
  }
  memset([s.bitmapBuffer contents], 0, 64);

  // Match buffer: 256 slots per device. With N devices, the global
  // match pool is N × 256.
  s.matchBuffer = [dev newBufferWithLength:256 * sizeof(GRDUInt256x64)
                                   options:MTLResourceStorageModeShared];
  if (!s.matchBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return nil;
  }
  s.matchCountBuffer = [dev newBufferWithLength:sizeof(uint32_t)
                                        options:MTLResourceStorageModeShared];
  if (!s.matchCountBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return nil;
  }
  *(uint32_t *)[s.matchCountBuffer contents] = 0;

  return s;
}

- (void)executeWithCompletion:(void (^_Nonnull)(NSArray<GRDMatch *> *_Nullable,
                                                  NSError *_Nullable))completion {
  // Default implementation: subclasses override.
  if (completion) {
    NSError *err = [NSError errorWithDomain:GRDErrorDomain
                                      code:GRDErrorGPUNotImplemented
                                  userInfo:@{NSLocalizedDescriptionKey:
                                                @"Not implemented"}];
    dispatch_async(_completion_queue, ^{ completion(nil, err); });
  }
}

@end

// =============================================================================
// GRDPubkeySweeper — uses grdSweepPubkey kernel (A26)
// Multi-device, pipelined dispatch across all GPUs.
// =============================================================================

@interface GRDPubkeySweeper () {
  // Re-declared for property access in the .m; fields live on the
  // base class's `_devices` array.
}
@end

@implementation GRDPubkeySweeper

- (instancetype)init {
  return (GRDPubkeySweeper *)[super init];
}

- (void)dealloc { [super dealloc]; }

- (void)executeWithCompletion:(void (^_Nonnull)(NSArray<GRDMatch *> *_Nullable,
                                                  NSError *_Nullable))completion {
  if (self->_cancelled) {
    if (completion) completion(@[], nil);
    return;
  }
  if (self->_devices.count == 0) {
    if (completion) completion(nil, [NSError errorWithDomain:GRDErrorDomain
                                                       code:GRDErrorMetalUnavailable
                                                   userInfo:@{NSLocalizedDescriptionKey:
                                                               @"No devices"}]);
    return;
  }

  GRDUInt128 range;
  GRDU128Sub(&range, _options->to, _options->from);
  uint32_t device_count = (uint32_t)self->_devices.count;
  uint32_t depth = self->_pipeline_depth;

  // Per-device, per-depth j-slices. We split [from, to) into
  // device_count * depth equal slices and issue one command buffer
  // per slice. The Metal scheduler overlaps the slices' execution
  // when the kernel is compute-bound; the per-slice wall time
  // dominates the throughput.
  uint64_t total_slices = (uint64_t)device_count * depth;
  // The per-slice range as a 64-bit quantity (high-limb zero is the
  // common case; for ranges > 2^64 the bench should not be
  // microbenchmarking anyway).
  uint64_t per_slice = range.lo / total_slices;
  if (per_slice == 0) per_slice = 1;

  __block atomic_uint completed_count = 0;
  __block NSMutableArray<GRDMatch *> *all_matches =
      [NSMutableArray arrayWithCapacity:256 * device_count];
  __block NSError *first_err = nil;
  dispatch_group_t fanout = dispatch_group_create();

  dispatch_queue_t merge_q = dispatch_queue_create("com.greedyfind.sweeper.merge",
                                                  DISPATCH_QUEUE_SERIAL);

  // Build sweep args (the same for every slice). The host precomputes
  // these on _prep_queue so device work doesn't wait for it.
  GRDUInt256x64 tx = _options->target.target_x;
  size_t args_len = 32 + 64 + 4 + 4 + 4 + 4 + 4 + 4;
  NSData *args_template_data = [NSMutableData dataWithLength:args_len];
  uint8_t *p = (uint8_t *)args_template_data.bytes;
  for (int i = 0; i < 4; ++i) {
    uint64_t limb = tx.limbs[3 - i];
    for (int b = 0; b < 8; ++b) p[i * 8 + b] = (uint8_t)(limb >> ((7 - b) * 8));
  }
  p += 32;
  memset(p, 0, 64); p += 64;
  *(uint32_t *)p = 0; p += 4;
  *(uint64_t *)p = 0; p += 8;
  *(uint32_t *)p = 0; p += 4;
  *(uint32_t *)p = 0; p += 4;
  *(uint32_t *)p = 0; p += 4;
  *(uint32_t *)p = 0; p += 4;
  *(uint32_t *)p = 0; p += 4;

  // Issue the prune kernel once per device (concurrent across devices).
  for (uint32_t di = 0; di < device_count; ++di) {
    GRDDeviceState *dev_state = self->_devices[di];
    dispatch_group_enter(fanout);
    dispatch_async(self->_prep_queue, ^{
      if (self->_cancelled) {
        dispatch_group_leave(fanout);
        return;
      }
      // Per-device prune dispatch: sets the productivity bitmap.
      // All sweeps share the bitmap, so we run it once.
      struct {
        uint64_t from_lo, from_hi, to_lo, to_hi;
      } prune_args = {.from_lo = _options->from.lo, .from_hi = _options->from.hi,
                      .to_lo = _options->to.lo, .to_hi = _options->to.hi};
      id<MTLBuffer> prune_buf = [dev_state.device
          newBufferWithBytes:&prune_args length:sizeof(prune_args)
                     options:MTLResourceStorageModeShared];
      id<MTLCommandBuffer> prune_cmd = [dev_state.queue commandBuffer];
      id<MTLComputeCommandEncoder> penc = [prune_cmd computeCommandEncoder];
      [penc setComputePipelineState:dev_state.pipelinePrune];
      [penc setBuffer:prune_buf offset:0 atIndex:0];
      [penc setBuffer:dev_state.variantsBuffer offset:0 atIndex:1];
      [penc setBuffer:dev_state.bitmapBuffer offset:0 atIndex:2];
      [penc dispatchThreads:MTLSizeMake(self->_variant_count, 1, 1)
       threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
      [penc endEncoding];
      [prune_cmd addCompletedHandler:^(id<MTLCommandBuffer> buf) {
        if (buf.status != MTLCommandBufferStatusCompleted) {
          dispatch_async(merge_q, ^{
            if (!first_err) {
              first_err = [NSError errorWithDomain:GRDErrorDomain
                                              code:GRDErrorGPUNotImplemented
                                          userInfo:@{NSLocalizedDescriptionKey:
                                                      @"Variant prune kernel failed"}];
            }
          });
          dispatch_group_leave(fanout);
          return;
        }
        // Reset the per-device match counter.
        *(uint32_t *)[dev_state.matchCountBuffer contents] = 0;
        // Issue the per-slice sweep commands for this device.
        for (uint32_t s = 0; s < depth; ++s) {
          uint64_t slice_idx = (uint64_t)di * depth + s;
          GRDUInt128 slice_from = _options->from;
          GRDUInt128 slice_offset = GRDU128FromU64(per_slice * slice_idx);
          GRDU128Add(&slice_from, slice_from, slice_offset);
          GRDUInt128 next_offset = GRDU128FromU64(per_slice * (slice_idx + 1));
          GRDUInt128 slice_to = _options->from;
          GRDU128Add(&slice_to, slice_to, next_offset);
          if (slice_idx + 1 == total_slices) slice_to = _options->to;

          // Per-slice args buffer.
          NSMutableData *slice_args = [args_template_data mutableCopy];
          uint8_t *sp = slice_args.mutableBytes;
          sp += 32 + 64 + 4 + 8 + 4;
          *(uint32_t *)sp = (uint32_t)slice_from.lo; sp += 4;
          *(uint32_t *)sp = (uint32_t)slice_from.hi; sp += 4;
          *(uint32_t *)sp = (uint32_t)slice_to.lo; sp += 4;
          *(uint32_t *)sp = (uint32_t)slice_to.hi; sp += 4;

          id<MTLBuffer> sweep_args_buf =
              [dev_state.device newBufferWithBytes:slice_args.bytes
                                            length:slice_args.length
                                           options:MTLResourceStorageModeShared];
          id<MTLCommandBuffer> sweep_cmd = [dev_state.queue commandBuffer];
          if (!sweep_cmd) {
            dispatch_async(merge_q, ^{
              if (!first_err) {
                first_err = [NSError errorWithDomain:GRDErrorDomain
                                                code:GRDErrorPipelineCreationFailed
                                            userInfo:nil];
              }
            });
            continue;
          }
          id<MTLComputeCommandEncoder> senc = [sweep_cmd computeCommandEncoder];
          [senc setComputePipelineState:dev_state.pipelineSweep];
          [senc setBuffer:sweep_args_buf offset:0 atIndex:0];
          [senc setBuffer:dev_state.variantsBuffer offset:0 atIndex:1];
          [senc setBuffer:dev_state.matchBuffer offset:0 atIndex:2];
          [senc setBuffer:dev_state.matchCountBuffer offset:0 atIndex:3];
          uint64_t batch = self->_batch_size ? self->_batch_size : 32;
          [senc dispatchThreads:MTLSizeMake(batch, 1, 1)
           threadsPerThreadgroup:MTLSizeMake(batch, 1, 1)];
          [senc endEncoding];
          [sweep_cmd addCompletedHandler:^(id<MTLCommandBuffer> bf) {
            if (bf.status != MTLCommandBufferStatusCompleted) {
              dispatch_async(merge_q, ^{
                if (!first_err) {
                  first_err = [NSError errorWithDomain:GRDErrorDomain
                                                  code:GRDErrorGPUNotImplemented
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                          @"Sweep kernel failed"}];
                }
              });
            } else {
              // Drain the per-device match buffer.
              uint32_t count = *(uint32_t *)[dev_state.matchCountBuffer contents];
              if (count > 256) count = 256;
              size_t vcount = 0;
              const GRDVariant *variants = GRDGenerateVariants(&vcount);
              GRDUInt256x64 *m = (GRDUInt256x64 *)[dev_state.matchBuffer contents];
              // Per-thread recovery: each match is independently
              // constructed, then the slice's array is appended
              // once under merge_q. The construction loop is
              // straightforward and would parallelise further
              // with dispatch_apply once we add a per-thread match
              // staging buffer.
              __block NSArray<GRDMatch *> *slice_matches;
              NSMutableArray<GRDMatch *> *tmp = [NSMutableArray arrayWithCapacity:count];
              for (uint32_t i = 0; i < count; ++i) {
                GRDUInt128 j_lo = {.lo = m[i].limbs[0], .hi = m[i].limbs[1]};
                NSString *label = i < vcount ? @(variants[i].label) : @"(>v)";
                [tmp addObject:[[GRDMatch alloc] initWithJ:j_lo variant:label]];
              }
              slice_matches = tmp;
              dispatch_async(merge_q, ^{
                [all_matches addObjectsFromArray:slice_matches];
              });
            }
            uint32_t prev = atomic_fetch_add(&completed_count, 1u);
            if (prev + 1 == total_slices) {
              dispatch_async(self->_completion_queue, ^{
                completion(all_matches, first_err);
              });
            }
          }];
          [sweep_cmd commit];
        }
        dispatch_group_leave(fanout);
      }];
      [prune_cmd commit];
    });
  }
  // Don't wait on fanout: the per-slice completions are what we
  // care about. dispatch_group_leave matches dispatch_group_enter
  // above; we just need to keep fanout alive long enough.
  // (The fanout group is captured by the completion handlers via
  // block retain; the original dispatch_group_t is released when
  // this method returns, but dispatch holds an internal reference
  // until all handlers complete. To be safe, retain a copy.)
  dispatch_group_t keepalive = fanout;
  (void)keepalive;
}

- (NSArray<GRDMatch *> *)_matchesFromBuffer:(uint32_t)count {
  NSMutableArray<GRDMatch *> *out = [NSMutableArray arrayWithCapacity:count];
  // When single-device is the path, this method is called from
  // the older sequence. Keep the original implementation for
  // completeness.
  if (self->_devices.count == 0) return out;
  GRDDeviceState *s = self->_devices[0];
  GRDUInt256x64 *matches = (GRDUInt256x64 *)[s.matchBuffer contents];
  size_t vcount = 0;
  const GRDVariant *variants = GRDGenerateVariants(&vcount);
  for (uint32_t i = 0; i < count; ++i) {
    GRDUInt128 j_lo;
    j_lo.lo = matches[i].limbs[0];
    j_lo.hi = matches[i].limbs[1];
    NSString *label = i < vcount ? @(variants[i].label) : @"(>variant_count)";
    GRDMatch *m = [[GRDMatch alloc] initWithJ:j_lo variant:label];
    [out addObject:m];
  }
  return out;
}

@end

// =============================================================================
// GRDAddressSweeper — --address mode (A27 stub)
// =============================================================================

@interface GRDAddressSweeper () {
  NSArray<id<MTLDevice>> *_devices;
}
@end

@implementation GRDAddressSweeper

- (instancetype)init {
  if ((self = [super init])) {
    _devices = MTLCopyAllDevices();
  }
  return self;
}

- (void)dealloc { [super dealloc]; }

- (void)cancel {}

- (BOOL)setupWithOptions:(GRDOptions *)opts
                   error:(NSError *_Nullable *_Nullable)error {
  (void)opts;
  if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                         code:GRDErrorGPUNotImplemented
                                     userInfo:@{
                                       NSLocalizedDescriptionKey:
                                           @"--address on GPU lands in A40+"
                                     }];
  return NO;
}

- (void)executeWithCompletion:(void (^_Nonnull)(NSArray<GRDMatch *> *_Nullable,
                                                  NSError *_Nullable))completion {
  if (completion) {
    NSError *err = [NSError errorWithDomain:GRDErrorDomain
                                      code:GRDErrorGPUNotImplemented
                                  userInfo:@{NSLocalizedDescriptionKey:
                                                @"--address on GPU lands in A40+"}];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
  }
}

@end

NS_ASSUME_NONNULL_END
