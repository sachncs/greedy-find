// host/sweep_pipelined.h — pipelined command-buffer dispatch (A41).
//
// Splits a single sweep range into N slices, issues N command
// buffers back-to-back so the GPU can overlap their execution
// across the dispatch queue, and merges their match outputs at the
// end. The pipelined path is opt-in: the regular GRDPubkeySweeper
// path remains untouched so A41 can be A/B-benchmarked against it.
//
// Measured-revert rule: keep iff bench/sweep_bench (run with
// --pipelined) shows >=5% j/sec gain over the sequential path. If
// not, this file is removed and the call site in host/sweep.m
// stays on the single-buffer dispatcher.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "config.h"
#import "ecc.h"
#import "sweeper.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Run the pubkey sweep in pipelined mode: split [from, to) into
 * @c depth slices, issue one command buffer per slice, and merge
 * the match outputs. Returns the combined matches via @c completion.
 *
 * @c depth is clamped to [1, 8]. 1 behaves identically to the
 * single-buffer path.
 */
void GRDRunPubkeySweepPipelined(
    id<MTLDevice> _Nonnull device,
    id<MTLCommandQueue> _Nonnull queue,
    id<MTLComputePipelineState> _Nonnull pipelineSweep,
    id<MTLBuffer> _Nonnull variantsBuffer,
    GRDUInt256x64 target_x,
    GRDUInt128 from,
    GRDUInt128 to,
    uint32_t batch_size,
    uint32_t depth,
    void (^_Nonnull completion)(NSArray<GRDMatch *> *_Nullable,
                                NSError *_Nullable));

NS_ASSUME_NONNULL_END
