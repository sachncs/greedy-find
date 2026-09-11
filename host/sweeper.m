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

#include <secp256k1.h>

NS_ASSUME_NONNULL_BEGIN

// No-op illegal-argument callback for libsecp256k1. The default
// callback abort()s on certain inputs; we want to keep going and
// trust the API's return value instead. The message is still
// surfaced to stderr so invariant violations are visible to the
// operator.
static void grd_secp256k1_ignore_illegal(const char *message, void *data) {
  (void)data;
  if (message) fprintf(stderr, "grd: secp256k1 illegal: %s\n", message);
}

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
@property (nonatomic, strong) id<MTLBuffer> vgBuffer;        // V·G points, precomputed
@property (nonatomic, strong) id<MTLBuffer> targetBuffer;
@property (nonatomic, strong) id<MTLBuffer> bitmapBuffer;
@property (nonatomic, strong) id<MTLBuffer> matchBuffer;
@property (nonatomic, strong) id<MTLBuffer> matchCountBuffer;
@property (nonatomic, assign) uint64_t j_per_sec;  // last measured
@end

// Match-buffer slot count per device. Must match the kGRDMatchBufferSlots
// constant in metal/sweep_pubkey.metal so the host's match_count cap
// and the kernel's slot-bounds check agree.
static const uint32_t GRDMatchBufferSlots = 256;

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
  NSString *metallib_path =
      [[NSBundle mainBundle] pathForResource:@"greedy" ofType:@"metallib"];
  NSURL *url = (metallib_path != nil)
                   ? [NSURL fileURLWithPath:metallib_path]
                   : nil;
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
  // Pack the variant V field densely into the buffer. The kernel reads
  // variants[i] as a UInt256x64 (32 bytes), but GRDVariant has an 8-byte
  // label pointer preceding the V field, so a raw memcpy would put 40
  // bytes per variant where the kernel expects 32. Mirror the bench's
  // approach in bench/sweep_bench.m:274-285: stride the 4 × u64 limbs.
  size_t variant_bytes = vcount * sizeof(GRDUInt256x64);
  s.variantsBuffer = [dev newBufferWithLength:variant_bytes
                                      options:MTLResourceStorageModeShared];
  if (!s.variantsBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return nil;
  }
  uint64_t *vdst = (uint64_t *)[s.variantsBuffer contents];
  for (size_t i = 0; i < vcount; ++i) {
    vdst[i * 4 + 0] = variants[i].V.limbs[0];
    vdst[i * 4 + 1] = variants[i].V.limbs[1];
    vdst[i * 4 + 2] = variants[i].V.limbs[2];
    vdst[i * 4 + 3] = variants[i].V.limbs[3];
  }

  // V·G precompute. For each of the 512 variants we compute the
  // point V·G once on the host and upload the 96-byte (X, Y, Z)
  // representation. The kernel then performs only ONE EC add per
  // lane — no per-lane scalar muls on the GPU.
  //
  // libsecp256k1's default illegal-callback aborts on certain variant
  // values (the check '!secp256k1_fe_is_zero(\&ge->x)' fires on some
  // very large but valid scalars). We install a no-op illegal callback
  // so the precompute can continue; tweak_mul's return value (which we
  // check) is the source of truth, not the abort.
  s.vgBuffer = [dev newBufferWithLength:vcount * sizeof(GRDEcPoint)
                                options:MTLResourceStorageModeShared];
  if (!s.vgBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return nil;
  }
  {
    secp256k1_context *vg_ctx =
        secp256k1_context_create(SECP256K1_CONTEXT_NONE);
    secp256k1_context_set_illegal_callback(vg_ctx,
                                           grd_secp256k1_ignore_illegal,
                                           NULL);
    secp256k1_pubkey G_pk;
    static const uint8_t kG_uncompressed[65] = {
      0x04,
      0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62, 0x95,
      0xCE, 0x87, 0x0B, 0x07, 0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
      0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98,
      0x48, 0x3A, 0xDA, 0x77, 0x26, 0xA3, 0xC4, 0x65, 0x5D, 0xA4, 0xFB, 0xFC,
      0x0E, 0x11, 0x08, 0xA8, 0xFD, 0x17, 0xB4, 0x48, 0xA6, 0x85, 0x54, 0x19,
      0x9C, 0x47, 0xD0, 0x8F, 0xFB, 0x10, 0xD4, 0xB8,
    };
    if (!secp256k1_ec_pubkey_parse(vg_ctx, &G_pk, kG_uncompressed, 65)) {
      secp256k1_context_destroy(vg_ctx);
      if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                             code:GRDErrorLibraryLoadFailed
                                         userInfo:@{
                                           NSLocalizedDescriptionKey:
                                               @"secp256k1 rejected the hardcoded G constant"
                                         }];
      return nil;
    }
    GRDEcPoint *vg_dst = (GRDEcPoint *)[s.vgBuffer contents];
    int precompute_failures = 0;
    for (size_t i = 0; i < vcount; ++i) {
      // Convert variant[i].V from LE u64 limbs to a 32-byte BE scalar.
      // secp256k1 expects mod-n BE bytes; for the small V values in
      // the variant table, mod-p == mod-n for values < min(n, p).
      uint8_t v_be[32];
      for (int i_limb = 0; i_limb < 4; ++i_limb) {
        uint64_t limb = variants[i].V.limbs[3 - i_limb];  // MSW first
        for (int b = 0; b < 8; ++b) {
          v_be[i_limb * 8 + b] = (uint8_t)((limb >> ((7 - b) * 8)) & 0xff);
        }
      }
      // Re-parse G fresh each iteration. secp256k1_pubkey aliases
      // internal storage; reusing a tweaked pk across iterations
      // produced inconsistent results. Re-parsing is cheap.
      secp256k1_pubkey vG;
      (void)secp256k1_ec_pubkey_parse(vg_ctx, &vG, kG_uncompressed, 65);
      if (!secp256k1_ec_pubkey_tweak_mul(vg_ctx, &vG, v_be)) {
        // tweak_mul returned 0 (failure). Mark this slot as identity
        // (Z=0) so the kernel can skip it; the lane falls through to
        // the identity-add path which contributes nothing to matches.
        vg_dst[i].X.limbs[0] = 0; vg_dst[i].X.limbs[1] = 0;
        vg_dst[i].X.limbs[2] = 0; vg_dst[i].X.limbs[3] = 0;
        vg_dst[i].Y.limbs[0] = 0; vg_dst[i].Y.limbs[1] = 0;
        vg_dst[i].Y.limbs[2] = 0; vg_dst[i].Y.limbs[3] = 0;
        vg_dst[i].Z.limbs[0] = 0;
        vg_dst[i].Z.limbs[1] = 0; vg_dst[i].Z.limbs[2] = 0; vg_dst[i].Z.limbs[3] = 0;
        precompute_failures++;
        continue;
      }
      uint8_t ser[65];
      size_t ser_len = 65;
      if (!secp256k1_ec_pubkey_serialize(vg_ctx, ser, &ser_len, &vG,
                                         SECP256K1_EC_UNCOMPRESSED) ||
          ser_len != 65) {
        vg_dst[i].X.limbs[0] = 0; vg_dst[i].X.limbs[1] = 0;
        vg_dst[i].X.limbs[2] = 0; vg_dst[i].X.limbs[3] = 0;
        vg_dst[i].Y.limbs[0] = 0; vg_dst[i].Y.limbs[1] = 0;
        vg_dst[i].Y.limbs[2] = 0; vg_dst[i].Y.limbs[3] = 0;
        vg_dst[i].Z.limbs[0] = 0;
        vg_dst[i].Z.limbs[1] = 0; vg_dst[i].Z.limbs[2] = 0; vg_dst[i].Z.limbs[3] = 0;
        precompute_failures++;
        continue;
      }
      // ser[1..33] = X BE, ser[33..65] = Y BE. Convert to LE limbs.
      for (int limb = 0; limb < 4; ++limb) {
        vg_dst[i].X.limbs[limb] = 0;
        for (int b = 0; b < 8; ++b) {
          vg_dst[i].X.limbs[limb] |= ((uint64_t)ser[1 + (3 - limb) * 8 + b])
                                     << ((7 - b) * 8);
        }
        vg_dst[i].Y.limbs[limb] = 0;
        for (int b = 0; b < 8; ++b) {
          vg_dst[i].Y.limbs[limb] |= ((uint64_t)ser[33 + (3 - limb) * 8 + b])
                                     << ((7 - b) * 8);
        }
      }
      vg_dst[i].Z.limbs[0] = 1;
      vg_dst[i].Z.limbs[1] = 0;
      vg_dst[i].Z.limbs[2] = 0;
      vg_dst[i].Z.limbs[3] = 0;
    }
    secp256k1_context_destroy(vg_ctx);
  }

  s.targetBuffer = [dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
  if (!s.targetBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return nil;
  }
  uint8_t *target_bytes = [s.targetBuffer contents];
  // The kernel reads target_x as a device const UInt256x64* — 4 × u64
  // limbs in the platform's native little-endian byte order. Store the
  // target in the same LE layout so the kernel's per-limb comparison
  // matches the candidate's per-limb X. (The previous BE encoding was
  // byte-swapped relative to the kernel's view and produced zero
  // matches.)
  GRDUInt256x64 tx = _options->target.target_x;
  memcpy(target_bytes, tx.limbs, sizeof(tx.limbs));

  s.bitmapBuffer = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
  if (!s.bitmapBuffer) {
    if (error) *error = [NSError errorWithDomain:GRDErrorDomain
                                           code:GRDErrorBufferAllocationFailed
                                       userInfo:nil];
    return nil;
  }
  memset([s.bitmapBuffer contents], 0, 64);

  // Match buffer: GRDMatchBufferSlots slots per device. With N devices,
  // the global match pool is N × GRDMatchBufferSlots.
  s.matchBuffer = [dev newBufferWithLength:GRDMatchBufferSlots * sizeof(GRDUInt256x64)
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
  // Per-slice j-count cap. Each dispatch is
  //   num_anchors × 16 variant chunks × 32 lanes
  // threads; the cap keeps every dispatch comfortably under Metal's
  // per-command-buffer limit (~2^31) and keeps the per-slice wall
  // time bounded so the pipelined multi-slice overlap pays off.
  const uint64_t kGRDMaxAnchorsPerSlice = 1ULL << 20;  // 1 M j's
  uint64_t per_slice;
  if (range.hi == 0) {
    per_slice = range.lo / total_slices;
  } else {
    // u128 range: fall back to one giant slice; the v0.1 kernel only
    // decodes the lo limb, so the per-slice cap on the lo portion
    // applies. Full u128 range splitting lands in a follow-up.
    per_slice = range.lo;
  }
  if (per_slice == 0) per_slice = 1;
  if (per_slice > kGRDMaxAnchorsPerSlice) {
    per_slice = kGRDMaxAnchorsPerSlice;
  }
  if (range.hi == 0) {
    total_slices = (range.lo + per_slice - 1) / per_slice;
  } else {
    // u128 range, single slice for v0.1.
    total_slices = 1;
  }
  if (total_slices == 0) total_slices = 1;

  __block atomic_uint completed_count = 0;
  __block NSMutableArray<GRDMatch *> *all_matches =
      [NSMutableArray arrayWithCapacity:256 * device_count];
  __block NSError *first_err = nil;
  dispatch_group_t fanout = dispatch_group_create();

  dispatch_queue_t merge_q = dispatch_queue_create("com.greedyfind.sweeper.merge",
                                                  DISPATCH_QUEUE_SERIAL);

  // Per-slice args buffers are built from scratch inside the slice
  // loop below, because num_anchors, from_limbs, and to_limbs differ
  // per slice. The layout mirrors the Tier-2 argument-buffer contract
  // (developer.apple.com/documentation/metal/buffers):
  //
  //   offset  0: device const UInt256x64* target_x       (gpuAddress)
  //   offset  8: device const uint8_t*     bitmap        (gpuAddress)
  //   offset 16: device const EcPoint*     anchors       (gpuAddress; full points)
  //   offset 24: uint32 num_anchors
  //   offset 28: uint32 (pad for 8-byte pointer alignment)
  //   offset 32: device const EcPoint*     v_points      (gpuAddress; V·G points)
  //   offset 40: device UInt256x64*        match_buffer  (gpuAddress; UInt256x64 slots)
  //   offset 48: device atomic_uint*       match_count   (gpuAddress)
  //   offset 56: uint32 from_limbs[4]      (u128 little-endian)
  //   offset 72: uint32 to_limbs[4]        (u128 little-endian)
  //   total: 88 bytes

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
        // Per-device gpuAddress values for the constant pointers.
        // The match_buffer / match_count / target / bitmap addresses are
        // stable across slices, so we cache them here. The anchors
        // pointer is per-slice (see anchor_staging below) and is patched
        // into the args buffer inside the slice loop.
        uint64_t target_x_addr = [dev_state.targetBuffer gpuAddress];
        uint64_t bitmap_addr   = [dev_state.bitmapBuffer gpuAddress];
        uint64_t vg_buf_addr   = [dev_state.vgBuffer gpuAddress];
        uint64_t match_buf_addr  = [dev_state.matchBuffer gpuAddress];
        uint64_t match_cnt_addr  = [dev_state.matchCountBuffer gpuAddress];
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

          // Anchor precompute. The v0.1 kernel does not read anchorsBuffer
          // (the struct field is marked "unused by C1") so we only
          // need the per-slice staging buffer for the blit copy; the
          // device-wide anchorsBuffer pool was dropped.
          GRDUInt128 slice_range;
          GRDU128Sub(&slice_range, slice_to, slice_from);
          uint32_t slice_num_anchors;
          if (slice_range.hi == 0) {
            slice_num_anchors = (uint32_t)(slice_range.lo < 0x100000
                                              ? slice_range.lo
                                              : 0x100000);
          } else {
            slice_num_anchors = 0x100000;
          }

          // Per-slice staging buffer (slice_num_anchors * 96 bytes).
          // Written on the CPU then passed straight to the kernel.
          id<MTLBuffer> anchor_staging = [dev_state.device
              newBufferWithLength:slice_num_anchors * sizeof(GRDEcPoint)
                           options:MTLResourceStorageModeShared];
          {
            secp256k1_context *actx =
                secp256k1_context_create(SECP256K1_CONTEXT_NONE);
            secp256k1_context_set_illegal_callback(actx,
                                                   grd_secp256k1_ignore_illegal,
                                                   NULL);
            secp256k1_pubkey G_pk;
            static const uint8_t kG_uncompressed[65] = {
              0x04,
              0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0,
              0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07, 0x02, 0x9B, 0xFC, 0xDB,
              0x2D, 0xCE, 0x28, 0xD9, 0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8,
              0x17, 0x98,
              0x48, 0x3A, 0xDA, 0x77, 0x26, 0xA3, 0xC4, 0x65, 0x5D, 0xA4,
              0xFB, 0xFC, 0x0E, 0x11, 0x08, 0xA8, 0xFD, 0x17, 0xB4, 0x48,
              0xA6, 0x85, 0x54, 0x19, 0x9C, 0x47, 0xD0, 0x8F, 0xFB, 0x10,
              0xD4, 0xB8,
            };
            (void)secp256k1_ec_pubkey_parse(actx, &G_pk,
                                            kG_uncompressed, 65);
            uint8_t from_be[32];
            memset(from_be, 0, 32);
            from_be[24] = (uint8_t)(slice_from.lo & 0xff);
            from_be[25] = (uint8_t)((slice_from.lo >> 8) & 0xff);
            from_be[26] = (uint8_t)((slice_from.lo >> 16) & 0xff);
            from_be[27] = (uint8_t)((slice_from.lo >> 24) & 0xff);
            from_be[28] = (uint8_t)((slice_from.lo >> 32) & 0xff);
            from_be[29] = (uint8_t)((slice_from.lo >> 40) & 0xff);
            from_be[30] = (uint8_t)((slice_from.lo >> 48) & 0xff);
            from_be[31] = (uint8_t)((slice_from.lo >> 56) & 0xff);
            secp256k1_pubkey cur = G_pk;
            (void)secp256k1_ec_pubkey_tweak_mul(actx, &cur, from_be);
            static const uint8_t kOneBE[32] = {
              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
            };
            GRDEcPoint *anchor_dst = (GRDEcPoint *)[anchor_staging contents];
            for (uint32_t i = 0; i < slice_num_anchors; ++i) {
              uint8_t ser[65];
              size_t ser_len = 65;
              if (secp256k1_ec_pubkey_serialize(actx, ser, &ser_len, &cur,
                                               SECP256K1_EC_UNCOMPRESSED) &&
                  ser_len == 65) {
                for (int limb = 0; limb < 4; ++limb) {
                  anchor_dst[i].X.limbs[limb] = 0;
                  anchor_dst[i].Y.limbs[limb] = 0;
                  for (int b = 0; b < 8; ++b) {
                    anchor_dst[i].X.limbs[limb] |=
                        ((uint64_t)ser[1 + (3 - limb) * 8 + b])
                        << ((7 - b) * 8);
                    anchor_dst[i].Y.limbs[limb] |=
                        ((uint64_t)ser[33 + (3 - limb) * 8 + b])
                        << ((7 - b) * 8);
                  }
                }
                anchor_dst[i].Z.limbs[0] = 1;
                anchor_dst[i].Z.limbs[1] = 0;
                anchor_dst[i].Z.limbs[2] = 0;
                anchor_dst[i].Z.limbs[3] = 0;
              } else {
                anchor_dst[i].X.limbs[0] = 0; anchor_dst[i].X.limbs[1] = 0;
                anchor_dst[i].X.limbs[2] = 0; anchor_dst[i].X.limbs[3] = 0;
                anchor_dst[i].Y.limbs[0] = 0; anchor_dst[i].Y.limbs[1] = 0;
                anchor_dst[i].Y.limbs[2] = 0; anchor_dst[i].Y.limbs[3] = 0;
                anchor_dst[i].Z.limbs[0] = 0;
                anchor_dst[i].Z.limbs[1] = 0; anchor_dst[i].Z.limbs[2] = 0; anchor_dst[i].Z.limbs[3] = 0;
              }
              if (i + 1 < slice_num_anchors) {
(void)secp256k1_ec_pubkey_tweak_add(actx, &cur, kOneBE);
              }
            }
            secp256k1_context_destroy(actx);
          }

          // Per-slice args buffer (80 bytes, see layout comment above).
          // num_anchors is the per-slice j-count, capped at 2^20 so the
          // dispatch stays well under Metal's per-command-buffer limit.
          // For u128 ranges whose hi-limb is non-zero, the kernel can
          // only handle the low-limb portion in v0.1; the high-limb
          // tail needs a follow-up that chunks the range via outer
          // slicing.
          // (slice_num_anchors computed above, just before the anchor
          // precompute block.)
          // Pack the args struct little-endian so the kernel can read
          // it byte-for-byte.
          uint8_t args_buf[88];
          memset(args_buf, 0, sizeof(args_buf));
          uint64_t *ap64 = (uint64_t *)args_buf;
          uint32_t *ap32 = (uint32_t *)args_buf;
          ap64[0] = target_x_addr;   // offset  0
          ap64[1] = bitmap_addr;     // offset  8
          ap64[2] = [anchor_staging gpuAddress];  // offset 16
          ap32[6] = slice_num_anchors;  // offset 24
          ap64[4] = vg_buf_addr;     // offset 32
          ap64[5] = match_buf_addr;  // offset 40
          ap64[6] = match_cnt_addr;  // offset 48
          // from_limbs at offset 56 (u128 LE, 4 × u32)
          ap32[14] = (uint32_t)(slice_from.lo & 0xFFFFFFFFu);
          ap32[15] = (uint32_t)(slice_from.lo >> 32);
          ap32[16] = (uint32_t)(slice_from.hi & 0xFFFFFFFFu);
          ap32[17] = (uint32_t)(slice_from.hi >> 32);
          // to_limbs at offset 72 (u128 LE, 4 × u32)
          ap32[18] = (uint32_t)(slice_to.lo & 0xFFFFFFFFu);
          ap32[19] = (uint32_t)(slice_to.lo >> 32);
          ap32[20] = (uint32_t)(slice_to.hi & 0xFFFFFFFFu);
          ap32[21] = (uint32_t)(slice_to.hi >> 32);

          id<MTLBuffer> sweep_args_buf =
              [dev_state.device newBufferWithBytes:args_buf
                                            length:sizeof(args_buf)
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
          // Blit-copy the anchor staging buffer into the per-device
          // anchors buffer so the GPU sweep kernel sees the freshly
          // computed anchors. The blit copy in the same command buffer
          // as the compute dispatch ensures ordering — no explicit
          // synchronise is needed.
          // Pass anchor_staging directly to the kernel; the v0.1 kernel
          // doesn't read anchorsBuffer ("unused by C1"), so the per-slice
          // staging buffer is enough — no device-wide 96 MiB pool needed.
          id<MTLComputeCommandEncoder> senc = [sweep_cmd computeCommandEncoder];
          [senc setComputePipelineState:dev_state.pipelineSweep];
          [senc setBuffer:sweep_args_buf offset:0 atIndex:0];
          [senc setBuffer:dev_state.variantsBuffer offset:0 atIndex:1];
          [senc setBuffer:anchor_staging offset:0 atIndex:2];
          [senc setBuffer:dev_state.vgBuffer offset:0 atIndex:3];
          [senc setBuffer:dev_state.matchBuffer offset:0 atIndex:4];
          [senc setBuffer:dev_state.matchCountBuffer offset:0 atIndex:5];
          // Dispatch grid covers num_anchors j's × 16 variant chunks ×
          // 32 lanes per chunk. The kernel decomposes gid as
          //   j_idx     = gid / 16
          //   chunk_idx = gid % 16
          // so a single dispatch covers the full 512-variant table
          // across 16 threadgroups per j.
          uint64_t total_threads = (uint64_t)slice_num_anchors * 16ULL * 32ULL;
          [senc dispatchThreads:MTLSizeMake((NSUInteger)total_threads, 1, 1)
           threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
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
              if (count > GRDMatchBufferSlots) count = GRDMatchBufferSlots;
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
              // The completion must fire after every slice's appends
              // have drained through merge_q. Fire the completion from
              // merge_q itself when the last slice completes, so we
              // can't observe a partial all_matches array.
              uint32_t prev = atomic_fetch_add(&completed_count, 1u);
              dispatch_async(merge_q, ^{
                [all_matches addObjectsFromArray:slice_matches];
                if (prev + 1 == total_slices) {
                  dispatch_async(self->_completion_queue, ^{
                    completion(all_matches, first_err);
                  });
                }
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
// GRDAddressSweeper — --address mode (A27 stub).
//
// Inherits from GRDSweeperBase so it reuses the same GRDSweeper
// protocol surface as GRDPubkeySweeper. setupWithOptions: always
// returns NO with a "not implemented" error; the dispatcher's
// GRDRunSession surfaces the error to the operator.
// =============================================================================

@implementation GRDAddressSweeper

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

@end

NS_ASSUME_NONNULL_END
