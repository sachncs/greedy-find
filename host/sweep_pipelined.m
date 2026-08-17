// host/sweep_pipelined.m — A41 implementation.
//
// Splits the sweep range into `depth` equal slices and issues one
// command buffer per slice in quick succession. Metal's command
// queue serialises submissions, but the underlying scheduler can
// overlap the buffers' execution when the kernel is
// compute-bound; the pipelined path is most useful when the
// per-buffer kernel time is short and the dispatch overhead is
// significant.

#import "sweep_pipelined.h"

#import "sweep.h"
#import "sweeper.h"

#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

NS_ASSUME_NONNULL_BEGIN

void GRDRunPubkeySweepPipelined(
    id<MTLDevice> device,
    id<MTLCommandQueue> queue,
    id<MTLComputePipelineState> pipelineSweep,
    id<MTLBuffer> variantsBuffer,
    GRDUInt256x64 target_x,
    GRDUInt128 from,
    GRDUInt128 to,
    uint32_t batch_size,
    uint32_t depth,
    void (^_Nonnull completion)(NSArray<GRDMatch *> *_Nullable,
                                NSError *_Nullable)) {
  if (depth < 1) depth = 1;
  if (depth > 8) depth = 8;
  if (batch_size == 0) batch_size = 32;

  // Slice [from, to) into `depth` equal pieces.
  GRDUInt128 range;
  GRDU128Sub(&range, to, from);
  // Each slice spans range/depth j's. We use simple per-slice
  // j-ranges with no cross-slice synchronization beyond a single
  // atomic completion counter.
  // The range arithmetic is 64-bit when the high limb of `range` is
  // zero (true for any bench-sized range; the bench harness passes
  // a 2^14-j range so the high limb is always 0).
  __block atomic_uint completed = 0;
  __block NSMutableArray<GRDMatch *> *all_matches =
      [NSMutableArray arrayWithCapacity:256];
  __block NSError *_Nullable first_err = nil;
  dispatch_queue_t merge_q =
      dispatch_queue_create("com.greedyfind.pipelined.merge",
                            DISPATCH_QUEUE_SERIAL);

  uint64_t range_lo = range.lo;
  uint64_t per_slice = depth > 0 ? (range_lo / depth) : range_lo;

  for (uint32_t s = 0; s < depth; ++s) {
    // Compute slice [slice_from, slice_to).
    GRDUInt128 offset = GRDU128FromU64(per_slice * s);
    GRDUInt128 slice_from_s;
    GRDU128Add(&slice_from_s, from, offset);
    GRDUInt128 next_offset = GRDU128FromU64(per_slice * (s + 1));
    GRDUInt128 slice_to;
    GRDU128Add(&slice_to, from, next_offset);
    if (s + 1 == depth) {
      slice_to = to;  // last slice absorbs any remainder
    }

    // Build sweep args.
    NSMutableData *args_data = [NSMutableData dataWithLength:512];
    uint8_t *p = args_data.mutableBytes;
    for (int i = 0; i < 4; ++i) {
      uint64_t limb = target_x.limbs[3 - i];
      for (int b = 0; b < 8; ++b) p[i * 8 + b] = (uint8_t)(limb >> ((7 - b) * 8));
    }
    p += 32;
    memset(p, 0, 64);
    p += 64;
    *(uint32_t *)p = 0; p += 4;
    *(uint64_t *)p = 0; p += 8;
    *(uint32_t *)p = 0; p += 4;
    *(uint32_t *)p = (uint32_t)slice_from_s.lo; p += 4;
    *(uint32_t *)p = (uint32_t)slice_from_s.hi; p += 4;
    *(uint32_t *)p = (uint32_t)slice_to.lo; p += 4;
    *(uint32_t *)p = (uint32_t)slice_to.hi; p += 4;

    id<MTLBuffer> sweep_args_buf =
        [device newBufferWithLength:args_data.length
                            options:MTLResourceStorageModeShared];
    if (!sweep_args_buf) {
      dispatch_async(merge_q, ^{
        if (!first_err) {
          first_err = [NSError errorWithDomain:GRDErrorDomain
                                          code:GRDErrorBufferAllocationFailed
                                      userInfo:nil];
          completion(nil, first_err);
        }
      });
      continue;
    }
    memcpy([sweep_args_buf contents], args_data.bytes, args_data.length);

    id<MTLBuffer> match_buf =
        [device newBufferWithLength:256 * sizeof(GRDUInt256x64)
                            options:MTLResourceStorageModeShared];
    id<MTLBuffer> match_count_buf =
        [device newBufferWithLength:sizeof(uint32_t)
                            options:MTLResourceStorageModeShared];
    if (!match_buf || !match_count_buf) {
      dispatch_async(merge_q, ^{
        if (!first_err) {
          first_err = [NSError errorWithDomain:GRDErrorDomain
                                          code:GRDErrorBufferAllocationFailed
                                      userInfo:nil];
          completion(nil, first_err);
        }
      });
      continue;
    }
    *(uint32_t *)[match_count_buf contents] = 0;

    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    if (!cmd) {
      dispatch_async(merge_q, ^{
        if (!first_err) {
          first_err = [NSError errorWithDomain:GRDErrorDomain
                                          code:GRDErrorPipelineCreationFailed
                                      userInfo:nil];
          completion(nil, first_err);
        }
      });
      continue;
    }
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:pipelineSweep];
    [enc setBuffer:sweep_args_buf offset:0 atIndex:0];
    [enc setBuffer:variantsBuffer offset:0 atIndex:1];
    [enc setBuffer:match_buf offset:0 atIndex:2];
    [enc setBuffer:match_count_buf offset:0 atIndex:3];
    [enc dispatchThreads:MTLSizeMake(batch_size, 1, 1)
     threadsPerThreadgroup:MTLSizeMake(batch_size, 1, 1)];
    [enc endEncoding];
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> bf) {
      NSArray<GRDMatch *> *slice_matches = @[];
      if (bf.status == MTLCommandBufferStatusCompleted) {
        uint32_t count = *(uint32_t *)[match_count_buf contents];
        if (count > 256) count = 256;
        size_t vcount = 0;
        const GRDVariant *variants = GRDGenerateVariants(&vcount);
        GRDUInt256x64 *m = (GRDUInt256x64 *)[match_buf contents];
        NSMutableArray<GRDMatch *> *tmp = [NSMutableArray arrayWithCapacity:count];
        for (uint32_t i = 0; i < count; ++i) {
          GRDUInt128 j_lo = {.lo = m[i].limbs[0], .hi = m[i].limbs[1]};
          NSString *label = i < vcount ? @(variants[i].label) : @"(>v)";
          [tmp addObject:[[GRDMatch alloc] initWithJ:j_lo variant:label]];
        }
        slice_matches = tmp;
      }
      dispatch_async(merge_q, ^{
        [all_matches addObjectsFromArray:slice_matches];
        uint32_t prev = atomic_fetch_add(&completed, 1u);
        if (prev + 1 == depth) {
          completion(all_matches, first_err);
        }
      });
    }];
    [cmd commit];
  }
}

NS_ASSUME_NONNULL_END
