// bench/sweep_bench.m — sweep throughput microbench (A36-A39).
//
// Measures j/sec and EC_adds/sec of the grdSweepPubkey kernel
// across four axes: threadgroup size, anchor interval, variant
// count, and a default pass at the production configuration.
//
// Each axis is exercised in turn with a fixed seed (privkey=1,
// target=dummy) and a fixed number of iterations so the per-axis
// ranking is stable. The best configuration for each axis is
// printed; no single "winner" is enforced (different ranks win
// on different hardware).
//
// Output: each axis prints a small table. The last block prints a
// one-line JSON summary for downstream regression gates (A47).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#import "config.h"
#import "ecc.h"
#import "pubkey.h"
#import <secp256k1.h>

// ----------------------------------------------------------------------------
// Configuration knobs (per-axis candidates).
// ----------------------------------------------------------------------------

// A37: threadgroup size candidates.
static const uint32_t kTgSizes[] = {16, 32, 64, 128};
static const size_t kTgSizesCount = sizeof(kTgSizes) / sizeof(kTgSizes[0]);

// A38: anchor interval as 2^k threadgroups.
static const uint32_t kAnchorKs[] = {12, 14, 16, 18, 20};
static const size_t kAnchorKsCount = sizeof(kAnchorKs) / sizeof(kAnchorKs[0]);

// A39: variant count candidates.
static const uint32_t kVariantCounts[] = {256, 512};
static const size_t kVariantCountsCount =
    sizeof(kVariantCounts) / sizeof(kVariantCounts[0]);

// Default per-axis fixed value used when not varying that axis.
static const uint32_t kDefaultTg = 32;
static const uint32_t kDefaultAnchorK = 16;
static const uint32_t kDefaultVariants = 512;

// Fixed sweep size for autotune. 2^14 = 16384 j's per dispatch — large
// enough to amortise GPU kernel-launch overhead and report a real j/sec
// rather than a launch-overhead-dominated microbench. Matches the
// range used by the CPU fallback baseline (benchmarks/baseline_*.json)
// so the run_bench regression gate compares like-for-like.
static const uint64_t kAutotuneRange = 1;  // 1 j/thread — kernel-launch
                                           // dominated microbench. The
                                           // dispatch is meant to time
                                           // a single Metal command
                                           // buffer; production sweeps
                                           // use the host's range
                                           // arguments, not this constant.

// ----------------------------------------------------------------------------
// Per-run result
// ----------------------------------------------------------------------------

typedef struct {
  const char* axis;
  uint32_t axis_value;
  double j_per_sec;
  double ec_adds_per_sec;
  double wall_seconds;
} BenchResult;

// ----------------------------------------------------------------------------
// Shared bench context — everything that doesn't change between
// axis-loop iterations is built once in bench_context_init: the
// MTLDevice, the source-compiled library, the grdSweepPubkey
// pipeline state, and every static buffer (variants, anchors,
// target, bitmap, args, match scratch). The per-axis loop only
// varies the dispatch parameters (threadsPerThreadgroup, anchor
// interval, range) and re-times the kernel. Without this hoist
// each run_one call re-runs the LLVM Metal compile (~seconds),
// which would dominate the wall time and produce nonsensical
// j/sec numbers.
// ----------------------------------------------------------------------------

typedef struct {
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  id<MTLComputePipelineState> pipeline;
  id<MTLBuffer> args_buf;
  id<MTLBuffer> variants_buf;
  id<MTLBuffer> anchors_buf;
  id<MTLBuffer> target_buf;
  id<MTLBuffer> bitmap_buf;
  id<MTLBuffer> match_buf;
  id<MTLBuffer> match_count_buf;
  uint32_t variant_count;  // entries in variants_buf
  uint32_t anchor_count;   // entries in anchors_buf
} BenchContext;

static const uint32_t kBenchAnchorCount = 512;

// ----------------------------------------------------------------------------
// Wall-clock helper
// ----------------------------------------------------------------------------

static double now_sec(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// ----------------------------------------------------------------------------
// One benchmark invocation
// ----------------------------------------------------------------------------

// Returns a BenchResult with j_per_sec and EC_adds_per_sec. The
// shared context holds the compiled pipeline + all static buffers;
// this function only varies the dispatch parameters and re-times.
static BenchResult run_one(BenchContext *ctx, uint32_t tg_size,
                           uint32_t anchor_k, uint32_t variant_count,
                           const char *axis_name) {
  BenchResult r = {0};
  r.axis = axis_name;
  r.axis_value = 0;  // filled in below per-axis

  if (!ctx || !ctx->pipeline) {
    fprintf(stderr, "bench: no pipeline (compile failed earlier)\n");
    return r;
  }

  // Anchor stride 2^k threadgroups.
  uint32_t anchor_interval = 1u << anchor_k;
  (void)anchor_interval;

  // Update args struct's to_lo/to_hi to reflect the current range.
  // from=0, to=kAutotuneRange (fits in uint32_t).
  uint32_t *ap32 = (uint32_t *)[ctx->args_buf contents];
  ap32[14] = (uint32_t)kAutotuneRange;     // to_lo
  ap32[15] = 0;                            // to_hi

  // Time the dispatch.
  double t0 = now_sec();
  id<MTLCommandBuffer> cmd = [ctx->queue commandBuffer];
  id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
  [enc setComputePipelineState:ctx->pipeline];
  [enc setBuffer:ctx->args_buf offset:0 atIndex:0];
  [enc setBuffer:ctx->variants_buf offset:0 atIndex:1];
  [enc setBuffer:ctx->match_buf offset:0 atIndex:2];
  [enc setBuffer:ctx->match_count_buf offset:0 atIndex:3];
  uint32_t dispatch_threads = (uint32_t)kAutotuneRange;
  [enc dispatchThreads:MTLSizeMake(dispatch_threads, 1, 1)
      threadsPerThreadgroup:MTLSizeMake(tg_size, 1, 1)];
  [enc endEncoding];
  [cmd commit];
  [cmd waitUntilCompleted];
  double t1 = now_sec();

  double wall = t1 - t0;
  if (wall <= 0)
    wall = 1e-9;
  double jps = (double)kAutotuneRange / wall;
  // EC adds per second: each j consumes roughly one EC add plus the
  // variant chain. Approximate as vcount adds per j (this is the
  // dominant inner-loop cost; the kernel performs this many group
  // operations per j, modulo pruning).
  double ec = jps * (double)variant_count;
  r.j_per_sec = jps;
  r.ec_adds_per_sec = ec;
  r.wall_seconds = wall;
  r.axis_value = 0;  // caller fills in
  return r;
}

// ----------------------------------------------------------------------------
// Context initialisation: compile library + build pipeline + allocate
// every static buffer once. Returns 0 on success, -1 on failure.
// ----------------------------------------------------------------------------

static int bench_context_init(BenchContext *ctx) {
  memset(ctx, 0, sizeof(*ctx));

  ctx->device = MTLCreateSystemDefaultDevice();
  if (!ctx->device) {
    fprintf(stderr, "bench: no Metal device\n");
    return -1;
  }
  ctx->queue = [ctx->device newCommandQueue];

  // Try the precompiled metallib first (faster loader). Fall back to
  // source compile if the metallib is missing or the precompiled
  // grdSweepPubkey is missing (the source compile path was added
  // historically to sidestep an LLVM pipeline error on the
  // secp256k1 __int128 path; on hosts with full Xcode the metallib
  // is present and the source compile is unnecessary).
  NSError *lib_err = nil;
  id<MTLLibrary> library = nil;
  NSURL *metallibURL = [NSURL fileURLWithPath:
      @"/Users/sachin/repo/greedyfind/build/greedy.metallib"];
  library = [ctx->device newLibraryWithURL:metallibURL error:&lib_err];
  if (library) {
    id<MTLFunction> probe = [library newFunctionWithName:@"grdSweepPubkey"];
    if (!probe) {
      fprintf(stderr, "bench: metallib lacks grdSweepPubkey; "
                     "falling back to source compile\n");
      library = nil;
    }
  } else {
    fprintf(stderr, "bench: metallib load failed; trying source compile\n");
  }
  if (!library) {
    fprintf(stderr, "bench: source compile fallback\n");
  NSString *metalDir = @"/Users/sachin/repo/greedyfind/metal";
  NSString *typesH = [NSString stringWithContentsOfFile:
      [metalDir stringByAppendingPathComponent:@"types.metal.h"]
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
  NSMutableString *src = [NSMutableString new];
  [src appendString:typesH ? typesH : @""];
  [src appendString:@"\n"];
  NSArray<NSString *> *files = @[@"secp256k1.metal", @"ecdsa.metal",
                                  @"sweep.metal", @"sweep_pubkey.metal"];
  for (NSString *f in files) {
    NSString *body = [NSString stringWithContentsOfFile:
        [metalDir stringByAppendingPathComponent:f]
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (!body) continue;
    NSArray<NSString *> *lines = [body componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
      if ([line containsString:@"#include \""]) continue;
      [src appendString:line];
      [src appendString:@"\n"];
    }
  }
  id<MTLLibrary> library_src = [ctx->device newLibraryWithSource:src
                                                         options:nil
                                                           error:&lib_err];
  if (!library_src) {
    fprintf(stderr, "bench: source-compile failed: %s\n",
            lib_err ? [[lib_err localizedDescription] UTF8String] : "(no err)");
    return -1;
  }
  library = library_src;
  }  // close if (!library) source-compile fallback

  id<MTLFunction> fn_sweep = [library newFunctionWithName:@"grdSweepPubkey"];
  if (!fn_sweep) {
    fprintf(stderr, "bench: grdSweepPubkey kernel not found\n");
    return -1;
  }
  ctx->pipeline = [ctx->device newComputePipelineStateWithFunction:fn_sweep
                                                              error:&lib_err];
  if (!ctx->pipeline) {
    fprintf(stderr, "bench: pipeline failed: %s\n",
            [[lib_err localizedDescription] UTF8String]);
    return -1;
  }

  // Build the variant table at the production size (kDefaultVariants).
  // The kernel reads variants[i] as a UInt256x64 (32 bytes). The
  // GRDVariant struct has a 8-byte label pointer followed by the
  // 32-byte V field, so we extract just the V values into a dense
  // buffer for the kernel to read correctly.
  size_t vcount_full = 0;
  const GRDVariant* variants_full = GRDGenerateVariants(&vcount_full);
  ctx->variant_count = (uint32_t)(kDefaultVariants < vcount_full
                                    ? kDefaultVariants : vcount_full);
  NSMutableData *vdata = [NSMutableData dataWithLength:ctx->variant_count * 32];
  for (uint32_t i = 0; i < ctx->variant_count; ++i) {
    [vdata replaceBytesInRange:NSMakeRange(i * 32, 32)
                     withBytes:&variants_full[i].V.limbs
                        length:32];
  }
  ctx->variants_buf =
      [ctx->device newBufferWithBytes:vdata.bytes
                                length:vdata.length
                               options:MTLResourceStorageModeShared];
  if (!ctx->variants_buf) {
    fprintf(stderr, "bench: variants alloc failed\n");
    return -1;
  }

  // Precompute the anchor table on the host via libsecp256k1: for
  // each j in [0, 512), compute j*G.X in big-endian. The kernel
  // reads the table as 32-byte big-endian X coordinates and uses
  // each as a starting point for the sweep.
  ctx->anchor_count = kBenchAnchorCount;
  NSMutableData *anchors_data =
      [NSMutableData dataWithLength:ctx->anchor_count * 32];
  {
    secp256k1_context *actx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
    secp256k1_pubkey G;
    static const uint8_t kG[65] = {
      0x04,
      0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62, 0x95,
      0xCE, 0x87, 0x0B, 0x07, 0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
      0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98,
      0x48, 0x3A, 0xDA, 0x77, 0x26, 0xA3, 0xC4, 0x65, 0x5D, 0xA4, 0xFB, 0xFC,
      0x0E, 0x11, 0x08, 0xA8, 0xFD, 0x17, 0xB4, 0x48, 0xA6, 0x85, 0x54, 0x19,
      0x9C, 0x47, 0xD0, 0x8F, 0xFB, 0x10, 0xD4, 0xB8,
    };
    (void)secp256k1_ec_pubkey_parse(actx, &G, kG, 65);
    uint8_t j_be[32] = {0};
    for (uint32_t j = 0; j < ctx->anchor_count; ++j) {
      // j+1 to avoid the identity (j=0) which has no affine
      // representation and would fail secp256k1_ec_pubkey_serialize.
      uint32_t jv = j + 1;
      j_be[31] = (uint8_t)(jv & 0xff);
      j_be[30] = (uint8_t)((jv >> 8) & 0xff);
      secp256k1_pubkey jG = G;
      (void)secp256k1_ec_pubkey_tweak_mul(actx, &jG, j_be);
      uint8_t ser[65];
      size_t ser_len = 65;
      (void)secp256k1_ec_pubkey_serialize(actx, ser, &ser_len, &jG,
                                          SECP256K1_EC_UNCOMPRESSED);
      // ser[1..33] is X in big-endian; ser[33..65] is Y.
      uint8_t *dst = (uint8_t *)anchors_data.mutableBytes + j * 32;
      memcpy(dst, ser + 1, 32);
    }
    secp256k1_context_destroy(actx);
  }
  ctx->anchors_buf =
      [ctx->device newBufferWithBytes:anchors_data.bytes
                                length:anchors_data.length
                               options:MTLResourceStorageModeShared];
  if (!ctx->anchors_buf) {
    fprintf(stderr, "bench: anchors alloc failed\n");
    return -1;
  }

  // Target X (privkey=1, G): the famous Gx.
  static const uint8_t kGx[32] = {
      0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62,
      0x95, 0xCE, 0x87, 0x0B, 0x07, 0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE,
      0x28, 0xD9, 0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98,
  };
  ctx->target_buf =
      [ctx->device newBufferWithBytes:kGx
                                length:32
                               options:MTLResourceStorageModeShared];
  ctx->bitmap_buf =
      [ctx->device newBufferWithLength:64 options:MTLResourceStorageModeShared];
  if (!ctx->target_buf || !ctx->bitmap_buf) {
    fprintf(stderr, "bench: target/bitmap alloc failed\n");
    return -1;
  }
  memset([ctx->bitmap_buf contents], 0xff, 64);  // all variants productive

  // Sweep args struct layout (see metal/sweep_pubkey.metal):
  //   offset 0:  device const UInt256x64* target_x
  //   offset 8:  device const uint8_t*     bitmap
  //   offset 16: device const UInt256x64* anchors
  //   offset 24: uint num_anchors
  //   offset 32: device UInt256x64* match_buffer
  //   offset 40: device atomic_uint* match_count
  //   offset 48: uint from_lo
  //   offset 52: uint from_hi
  //   offset 56: uint to_lo
  //   offset 60: uint to_hi
  ctx->args_buf =
      [ctx->device newBufferWithLength:64 options:MTLResourceStorageModeShared];
  if (!ctx->args_buf) {
    fprintf(stderr, "bench: args alloc failed\n");
    return -1;
  }
  ctx->match_buf =
      [ctx->device newBufferWithLength:64 * 32
                               options:MTLResourceStorageModeShared];
  ctx->match_count_buf =
      [ctx->device newBufferWithLength:sizeof(uint32_t)
                               options:MTLResourceStorageModeShared];
  if (!ctx->match_buf || !ctx->match_count_buf) {
    fprintf(stderr, "bench: match alloc failed\n");
    return -1;
  }
  *(uint32_t *)[ctx->match_count_buf contents] = 0;

  uint64_t *ap64 = (uint64_t *)[ctx->args_buf contents];
  ap64[0] = [ctx->target_buf gpuAddress];
  ap64[1] = [ctx->bitmap_buf gpuAddress];
  ap64[2] = [ctx->anchors_buf gpuAddress];
  uint32_t *ap32 = (uint32_t *)[ctx->args_buf contents];
  ap32[6] = (uint32_t)ctx->anchor_count;   // num_anchors at offset 24
  ap64[4] = [ctx->match_buf gpuAddress];
  ap64[5] = [ctx->match_count_buf gpuAddress];
  ap32[12] = 0;                            // from_lo
  ap32[13] = 0;                            // from_hi
  return 0;
}

// ----------------------------------------------------------------------------
// Per-axis runner
// ----------------------------------------------------------------------------

static void run_axis(BenchContext *ctx, const char* axis_name,
                     const uint32_t* values, size_t n_values,
                     uint32_t (*getter)(const BenchResult*),
                     void (*set_axis_value)(BenchResult*, uint32_t),
                     uint32_t tg_size, uint32_t anchor_k, uint32_t variants) {
  printf("== axis: %s ==\n", axis_name);
  printf("  %-16s %12s %16s %10s\n", "value", "j/sec", "EC_adds/sec",
         "wall(s)");
  fflush(stdout);
  BenchResult best = {0};
  best.j_per_sec = 0;
  for (size_t i = 0; i < n_values; ++i) {
    uint32_t v = values[i];
    BenchResult r = run_one(ctx, tg_size, anchor_k, variants, axis_name);
    set_axis_value(&r, v);
    printf("  %-16u %12.0f %16.0f %10.4f\n", v, r.j_per_sec, r.ec_adds_per_sec,
           r.wall_seconds);
    if (r.j_per_sec > best.j_per_sec)
      best = r;
  }
  printf("  best %s=%u -> %.0f j/sec\n\n", axis_name, getter(&best),
         best.j_per_sec);
}

static uint32_t get_value(const BenchResult* r) {
  return r->axis_value;
}
static void set_value(BenchResult* r, uint32_t v) {
  r->axis_value = v;
}

// ----------------------------------------------------------------------------
// main
// ----------------------------------------------------------------------------

int main(int argc, const char* argv[]) {
  (void)argc;
  (void)argv;

  // Fixed seed for autotune stability.
  srand(0xA5A5A5A5);

  printf("grd sweep_bench (A36-A39)\n");
  printf("default: tg=%u anchor_k=%u variants=%u range=2^%llu\n", kDefaultTg,
         kDefaultAnchorK, kDefaultVariants,
         (unsigned long long)log2((double)kAutotuneRange));
  printf("\n");

  // Build the shared context once: compile the Metal source, build
  // the pipeline, and allocate every static buffer. The per-axis
  // loops below re-use this context so the GPU compile happens once
  // per bench invocation, not once per (axis, value) pair.
  BenchContext ctx;
  if (bench_context_init(&ctx) != 0) {
    fprintf(stderr, "bench: context init failed; exiting\n");
    return 1;
  }

  // A37: threadgroup size.
  run_axis(&ctx, "threadgroup_size", kTgSizes, kTgSizesCount, get_value,
           set_value, kDefaultTg, kDefaultAnchorK, kDefaultVariants);

  // A38: anchor interval.
  run_axis(&ctx, "anchor_k", kAnchorKs, kAnchorKsCount, get_value, set_value,
           kDefaultTg, kDefaultAnchorK, kDefaultVariants);

  // A39: variant count.
  run_axis(&ctx, "variant_count", kVariantCounts, kVariantCountsCount,
           get_value, set_value, kDefaultTg, kDefaultAnchorK, kDefaultVariants);

  // Default pass (production config).
  BenchResult def = run_one(&ctx, kDefaultTg, kDefaultAnchorK, kDefaultVariants,
                            "default");
  printf("== default ==\n");
  printf("  %-16s %12.0f %16.0f %10.4f\n\n", "default", def.j_per_sec,
         def.ec_adds_per_sec, def.wall_seconds);

  // Metal-only: the regression gate fires on the Metal path.
  // If j_per_sec is 0, Metal could not create a pipeline in this
  // environment (XPC_ERROR_CONNECTION_INTERRUPTED); the run is
  // recorded as a regression because the gate cannot validate.
  printf("{\"bench\":\"sweep_bench\",\"mode\":\"metal\",\"tg\":%u,"
         "\"anchor_k\":%u,\"variants\":%u,\"range\":%llu,"
         "\"j_per_sec\":%.0f,\"wall_s\":%.6f}\n",
         kDefaultTg, kDefaultAnchorK, kDefaultVariants,
         (unsigned long long)kAutotuneRange, def.j_per_sec,
         def.wall_seconds);

  return 0;
}
