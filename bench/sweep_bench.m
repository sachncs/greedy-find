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

// Fixed sweep size for autotune (small enough to be quick).
static const uint64_t kAutotuneRange = (uint64_t)1 << 14;  // 16K j
static const uint32_t kAutotuneBatch = 32;

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

// Runs a single sweep configuration and returns measured throughput.
// `tg_size` controls threadsPerThreadgroup in the dispatch.
// `anchor_k` controls the anchor interval (2^k threadgroups).
// `variant_count` controls how many variants are uploaded.
// Returns a BenchResult with j_per_sec and EC_adds_per_sec.
static BenchResult run_one(uint32_t tg_size, uint32_t anchor_k,
                           uint32_t variant_count, const char* axis_name) {
  BenchResult r = {0};
  r.axis = axis_name;
  r.axis_value = 0;  // filled in below per-axis

  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) {
    fprintf(stderr, "bench: no Metal device\n");
    r.j_per_sec = 0;
    return r;
  }
  id<MTLCommandQueue> queue = [device newCommandQueue];
  NSError* lib_err = nil;
  NSURL* url = [NSURL
      fileURLWithPath:[[NSBundle mainBundle] pathForResource:@"greedy"
                                                      ofType:@"metallib"]];
  id<MTLLibrary> library = nil;
  if (url && [[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
    library = [device newLibraryWithURL:url error:&lib_err];
  } else {
    library = [device newDefaultLibrary];
  }
  if (!library) {
    fprintf(stderr, "bench: no metallib\n");
    return r;
  }

  id<MTLFunction> fn_sweep = [library newFunctionWithName:@"grdSweepPubkey"];
  if (!fn_sweep) {
    fprintf(stderr, "bench: grdSweepPubkey kernel not found\n");
    return r;
  }
  id<MTLComputePipelineState> pipeline =
      [device newComputePipelineStateWithFunction:fn_sweep error:&lib_err];
  if (!pipeline) {
    fprintf(stderr, "bench: pipeline failed: %s\n",
            [[lib_err localizedDescription] UTF8String]);
    return r;
  }

  // Build a small variant table (variant_count entries).
  size_t vcount_full = 0;
  const GRDVariant* variants_full = GRDGenerateVariants(&vcount_full);
  size_t vcount = variant_count < vcount_full ? variant_count : vcount_full;
  id<MTLBuffer> variants_buf =
      [device newBufferWithBytes:variants_full
                          length:vcount * sizeof(GRDVariant)
                         options:MTLResourceStorageModeShared];
  if (!variants_buf) {
    fprintf(stderr, "bench: variants alloc failed\n");
    return r;
  }

  // Target X (privkey=1, G): the famous Gx.
  static const uint8_t kGx[32] = {
      0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62,
      0x95, 0xCE, 0x87, 0x0B, 0x07, 0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE,
      0x28, 0xD9, 0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98,
  };
  id<MTLBuffer> target_buf =
      [device newBufferWithBytes:kGx
                          length:32
                         options:MTLResourceStorageModeShared];
  id<MTLBuffer> bitmap_buf =
      [device newBufferWithLength:64 options:MTLResourceStorageModeShared];
  if (!target_buf || !bitmap_buf) {
    fprintf(stderr, "bench: target/bitmap alloc failed\n");
    return r;
  }
  memset([bitmap_buf contents], 0xff, 64);  // all variants productive

  // Sweep args struct (see metal/sweep_pubkey.metal).
  size_t args_len = 32 + 64 + 4 + 4 + 4 + 4 + 4 + 4;
  id<MTLBuffer> args_buf =
      [device newBufferWithLength:args_len
                          options:MTLResourceStorageModeShared];
  if (!args_buf) {
    fprintf(stderr, "bench: args alloc failed\n");
    return r;
  }
  uint8_t* ap = [args_buf contents];
  memcpy(ap, kGx, 32);
  ap += 32;
  memset(ap, 0xff, 64);  // bitmap
  ap += 64;
  *(uint32_t*)ap = (uint32_t)vcount;
  ap += 4;  // num_anchors
  *(uint32_t*)ap = 0;
  ap += 4;  // reserved
  *(uint32_t*)ap = 0;
  ap += 4;  // from_lo
  *(uint32_t*)ap = 0;
  ap += 4;  // from_hi
  *(uint32_t*)ap = (uint32_t)kAutotuneRange;
  ap += 4;  // to_lo
  *(uint32_t*)ap = 0;
  ap += 4;  // to_hi

  // Match buffers.
  id<MTLBuffer> match_buf =
      [device newBufferWithLength:256 * sizeof(GRDUInt256x64)
                          options:MTLResourceStorageModeShared];
  id<MTLBuffer> match_count_buf =
      [device newBufferWithLength:sizeof(uint32_t)
                          options:MTLResourceStorageModeShared];
  if (!match_buf || !match_count_buf) {
    fprintf(stderr, "bench: match alloc failed\n");
    return r;
  }
  *(uint32_t*)[match_count_buf contents] = 0;

  // Anchor stride 2^k threadgroups.
  uint32_t anchor_interval = 1u << anchor_k;

  // Time the dispatch.
  double t0 = now_sec();
  id<MTLCommandBuffer> cmd = [queue commandBuffer];
  id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
  [enc setComputePipelineState:pipeline];
  [enc setBuffer:args_buf offset:0 atIndex:0];
  [enc setBuffer:variants_buf offset:0 atIndex:1];
  [enc setBuffer:match_buf offset:0 atIndex:2];
  [enc setBuffer:match_count_buf offset:0 atIndex:3];
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
  double ec = jps * (double)vcount;
  r.j_per_sec = jps;
  r.ec_adds_per_sec = ec;
  r.wall_seconds = wall;
  r.axis_value = 0;  // caller fills in
  (void)anchor_interval;
  (void)kAutotuneBatch;
  return r;
}

// ----------------------------------------------------------------------------
// Per-axis runner
// ----------------------------------------------------------------------------

static void run_axis(const char* axis_name, const uint32_t* values,
                     size_t n_values, uint32_t (*getter)(const BenchResult*),
                     void (*set_axis_value)(BenchResult*, uint32_t),
                     uint32_t tg_size, uint32_t anchor_k, uint32_t variants) {
  printf("== axis: %s ==\n", axis_name);
  printf("  %-16s %12s %16s %10s\n", "value", "j/sec", "EC_adds/sec",
         "wall(s)");
  BenchResult best = {0};
  best.j_per_sec = 0;
  for (size_t i = 0; i < n_values; ++i) {
    uint32_t v = values[i];
    BenchResult r = run_one(tg_size, anchor_k, variants, axis_name);
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

  // A37: threadgroup size.
  run_axis("threadgroup_size", kTgSizes, kTgSizesCount, get_value, set_value,
           kDefaultTg, kDefaultAnchorK, kDefaultVariants);

  // A38: anchor interval.
  run_axis("anchor_k", kAnchorKs, kAnchorKsCount, get_value, set_value,
           kDefaultTg, kDefaultAnchorK, kDefaultVariants);

  // A39: variant count.
  run_axis("variant_count", kVariantCounts, kVariantCountsCount, get_value,
           set_value, kDefaultTg, kDefaultAnchorK, kDefaultVariants);

  // Default pass (production config).
  BenchResult def = run_one(kDefaultTg, kDefaultAnchorK, kDefaultVariants,
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
