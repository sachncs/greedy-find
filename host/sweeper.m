// host/sweeper.m — Metal device sweep implementations (A29-A32).
//
// Implements:
//   - GRDMatch (one match found by the sweeper).
//   - GRDSweeperBase: shared setup (creates device, queue, library).
//   - GRDPubkeySweeper (--pubkey mode; A26 kernel) — concrete subclass.
//   - GRDAddressSweeper (--address mode; A27 stub) — concrete subclass.
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
// GRDSweeperBase — common Metal setup
// =============================================================================

@interface GRDSweeperBase () {
 @public
  id<MTLDevice> _Nullable _device;
  id<MTLCommandQueue> _Nullable _queue;
  id<MTLLibrary> _Nullable _library;
  dispatch_queue_t _completion_queue;

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
    _variant_count = 512;
    _batch_size = 32;
    _anchor_interval_k = 16;
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

  _device = MTLCreateSystemDefaultDevice();
  if (!_device) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorMetalUnavailable
                                       userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"No Metal-compatible device found"
                                       }];
    return NO;
  }
  _queue = [_device newCommandQueue];
  if (!_queue) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorPipelineCreationFailed
                                       userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"Failed to create MTLCommandQueue"
                                       }];
    return NO;
  }
  NSError *lib_err = nil;
  NSURL *url = [NSURL fileURLWithPath:
      [[NSBundle mainBundle] pathForResource:@"greedy" ofType:@"metallib"]];
  if (url && [[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
    _library = [_device newLibraryWithURL:url error:&lib_err];
  } else {
    _library = [_device newDefaultLibrary];
  }
  if (!_library) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorLibraryLoadFailed
                                       userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"Failed to load greedy.metallib"
                                       }];
    return NO;
  }
  _setup_done = YES;
  return YES;
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
// =============================================================================

@interface GRDPubkeySweeper () {
  id<MTLComputePipelineState> _pipelinePrune;
  id<MTLComputePipelineState> _pipelineSweep;
  id<MTLBuffer> _Nullable _variantsBuffer;
  id<MTLBuffer> _Nullable _targetBuffer;
  id<MTLBuffer> _Nullable _bitmapBuffer;
  id<MTLBuffer> _Nullable _matchBuffer;
  id<MTLBuffer> _Nullable _matchCountBuffer;
}
@end

@implementation GRDPubkeySweeper

- (instancetype)init {
  return (GRDPubkeySweeper *)[super init];
}

- (void)dealloc { [super dealloc]; }

- (BOOL)setupWithOptions:(GRDOptions *)opts
                   error:(NSError *_Nullable *_Nullable)error {
  if (![super setupWithOptions:opts error:error]) return NO;

  NSError *lib_err = nil;
  id<MTLFunction> fn_prune = [_library newFunctionWithName:@"grdVariantPrune"];
  id<MTLFunction> fn_sweep = [_library newFunctionWithName:@"grdSweepPubkey"];
  if (!fn_prune || !fn_sweep) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorPipelineCreationFailed
                                       userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"Missing compute function"
                                       }];
    return NO;
  }
  _pipelinePrune = [_device newComputePipelineStateWithFunction:fn_prune
                                                            error:&lib_err];
  _pipelineSweep = [_device newComputePipelineStateWithFunction:fn_sweep
                                                            error:&lib_err];
  if (!_pipelinePrune || !_pipelineSweep) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorPipelineCreationFailed
                                       userInfo:lib_err ? @{
                                         NSUnderlyingErrorKey: lib_err
                                       } : nil];
    return NO;
  }

  size_t vcount = 0;
  const GRDVariant *variants = GRDGenerateVariants(&vcount);
  if (vcount != _variant_count) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorVariantIndexBuildFailed
                                       userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"Variant count mismatch"
                                       }];
    return NO;
  }
  size_t variant_bytes = vcount * sizeof(GRDVariant);
  _variantsBuffer = [_device
      newBufferWithLength:variant_bytes
                  options:MTLResourceStorageModeShared];
  if (!_variantsBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return NO;
  }
  memcpy([_variantsBuffer contents], variants, variant_bytes);

  _targetBuffer = [_device
      newBufferWithLength:32
                  options:MTLResourceStorageModeShared];
  if (!_targetBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return NO;
  }
  uint8_t *target_bytes = [_targetBuffer contents];
  GRDUInt256x64 tx = opts->target.target_x;
  for (int i = 0; i < 4; ++i) {
    uint64_t limb = tx.limbs[3 - i];
    for (int b = 0; b < 8; ++b) {
      target_bytes[i * 8 + b] = (uint8_t)(limb >> ((7 - b) * 8));
    }
  }

  _bitmapBuffer = [_device
      newBufferWithLength:64
                  options:MTLResourceStorageModeShared];
  if (!_bitmapBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return NO;
  }
  memset([_bitmapBuffer contents], 0, 64);

  _matchBuffer = [_device
      newBufferWithLength:256 * sizeof(GRDUInt256x64)
                  options:MTLResourceStorageModeShared];
  if (!_matchBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return NO;
  }
  _matchCountBuffer = [_device
      newBufferWithLength:sizeof(uint32_t)
                  options:MTLResourceStorageModeShared];
  if (!_matchCountBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return NO;
  }
  *(uint32_t *)[_matchCountBuffer contents] = 0;
  return YES;
}

- (void)executeWithCompletion:(void (^_Nonnull)(NSArray<GRDMatch *> *_Nullable,
                                                  NSError *_Nullable))completion {
  if (self->_cancelled) {
    if (completion) completion(@[], nil);
    return;
  }
  struct {
    uint64_t from_lo, from_hi, to_lo, to_hi;
  } prune_args;
  prune_args.from_lo = _options->from.lo;
  prune_args.from_hi = _options->from.hi;
  prune_args.to_lo = _options->to.lo;
  prune_args.to_hi = _options->to.hi;
  id<MTLBuffer> prune_args_buffer = [_device
      newBufferWithBytes:&prune_args
                  length:sizeof(prune_args)
                 options:MTLResourceStorageModeShared];
  if (!prune_args_buffer) {
    if (completion) completion(nil, [NSError errorWithDomain:GRDErrorDomain
                                                       code:GRDErrorBufferAllocationFailed
                                                   userInfo:nil]);
    return;
  }
  id<MTLCommandBuffer> cmd1 = [_queue commandBuffer];
  if (!cmd1) {
    if (completion) completion(nil, [NSError errorWithDomain:GRDErrorDomain
                                                       code:GRDErrorPipelineCreationFailed
                                                   userInfo:nil]);
    return;
  }
  id<MTLComputeCommandEncoder> enc1 = [cmd1 computeCommandEncoder];
  [enc1 setComputePipelineState:self->_pipelinePrune];
  [enc1 setBuffer:prune_args_buffer offset:0 atIndex:0];
  [enc1 setBuffer:self->_variantsBuffer offset:0 atIndex:1];
  [enc1 setBuffer:self->_bitmapBuffer offset:0 atIndex:2];
  [enc1 dispatchThreads:MTLSizeMake(self->_variant_count, 1, 1)
   threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
  [enc1 endEncoding];

  [cmd1 addCompletedHandler:^(id<MTLCommandBuffer> buf) {
    if (buf.status != MTLCommandBufferStatusCompleted) {
      if (completion) completion(nil, [NSError errorWithDomain:GRDErrorDomain
                                                       code:GRDErrorGPUNotImplemented
                                                   userInfo:@{NSLocalizedDescriptionKey:
                                                       @"Variant prune kernel failed"}]);
      return;
    }
    NSMutableData *args_data = [NSMutableData dataWithLength:512];
    uint8_t *p = args_data.mutableBytes;
    GRDUInt256x64 tx = _options->target.target_x;
    for (int i = 0; i < 4; ++i) {
      uint64_t limb = tx.limbs[3 - i];
      for (int b = 0; b < 8; ++b) p[i * 8 + b] = (uint8_t)(limb >> ((7 - b) * 8));
    }
    p += 32;
    memset(p, 0, 64);
    p += 64;
    *(uint32_t *)p = 0; p += 4;
    *(uint64_t *)p = 0; p += 8;
    *(uint32_t *)p = 0; p += 4;
    *(uint32_t *)p = (uint32_t)_options->from.lo; p += 4;
    *(uint32_t *)p = (uint32_t)_options->from.hi; p += 4;
    *(uint32_t *)p = (uint32_t)_options->to.lo; p += 4;
    *(uint32_t *)p = (uint32_t)_options->to.hi; p += 4;

    id<MTLBuffer> sweep_args_buf = [_device
        newBufferWithLength:args_data.length
                     options:MTLResourceStorageModeShared];
    if (!sweep_args_buf) {
      if (completion) completion(nil, [NSError errorWithDomain:GRDErrorDomain
                                                       code:GRDErrorBufferAllocationFailed
                                                   userInfo:nil]);
      return;
    }
    memcpy([sweep_args_buf contents], args_data.bytes, args_data.length);

    *(uint32_t *)[self->_matchCountBuffer contents] = 0;

    id<MTLCommandBuffer> cmd2 = [_queue commandBuffer];
    if (!cmd2) {
      if (completion) completion(nil, [NSError errorWithDomain:GRDErrorDomain
                                                       code:GRDErrorPipelineCreationFailed
                                                   userInfo:nil]);
      return;
    }
    id<MTLComputeCommandEncoder> enc2 = [cmd2 computeCommandEncoder];
    [enc2 setComputePipelineState:self->_pipelineSweep];
    [enc2 setBuffer:sweep_args_buf offset:0 atIndex:0];
    [enc2 setBuffer:self->_variantsBuffer offset:0 atIndex:1];
    [enc2 setBuffer:self->_matchBuffer offset:0 atIndex:2];
    [enc2 setBuffer:self->_matchCountBuffer offset:0 atIndex:3];
    uint64_t batch = self->_batch_size ? self->_batch_size : 32;
    [enc2 dispatchThreads:MTLSizeMake(batch, 1, 1)
     threadsPerThreadgroup:MTLSizeMake(batch, 1, 1)];
    [enc2 endEncoding];

    [cmd2 addCompletedHandler:^(id<MTLCommandBuffer> bf) {
      NSArray<GRDMatch *> *matches = @[];
      if (bf.status == MTLCommandBufferStatusCompleted) {
        uint32_t count = *(uint32_t *)[self->_matchCountBuffer contents];
        count = (count < 256 ? count : 256);
        matches = [self _matchesFromBuffer:count];
      }
      if (completion) {
        dispatch_async(_completion_queue, ^{
          completion(matches, nil);
        });
      }
    }];
    [cmd2 commit];
  }];
  [cmd1 commit];
}

- (NSArray<GRDMatch *> *)_matchesFromBuffer:(uint32_t)count {
  NSMutableArray<GRDMatch *> *out = [NSMutableArray arrayWithCapacity:count];
  GRDUInt256x64 *matches = (GRDUInt256x64 *)[self->_matchBuffer contents];
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
  id<MTLDevice> _Nullable _device;
}
@end

@implementation GRDAddressSweeper

- (instancetype)init {
  if ((self = [super init])) {
    _device = MTLCreateSystemDefaultDevice();
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
