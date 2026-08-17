// host/sweep.m — host-side dispatcher (A28-A32).
//
// Real argument parsing lives in host/config.m. The dispatcher here
// owns the help/version output, the mode-routing factory, and the
// GRDRunSession entry point that dispatches to a GRDSweeper instance
// (--pubkey: GRDPubkeySweeper; --address: GRDAddressSweeper) for the
// GPU path, or to a CPU fallback for tiny ranges.

#import "sweep.h"

#import "config.h"
#import "pubkey.h"
#import "address.h"
#import "sweeper.h"
#import "ecc.h"

#import <secp256k1.h>
#import <stdlib.h>
#import <string.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const GRDErrorDomain = @"com.greedyfind.error";

static void PrintUsage(const char *progname) {
  fprintf(stderr,
          "greedyfind — Metal-accelerated secp256k1 multi-variant range-"
          "splitting search\n"
          "\n"
          "Usage: %s [options]\n"
          "\n"
          "Required (one of):\n"
          "  --pubkey <hex>       SEC1 hex public key (compressed or uncompressed)\n"
          "  --address <base58>   P2PKH mainnet address (base58check)\n"
          "\n"
          "Required for both modes:\n"
          "  --from <int>         First scalar j in [from, to)\n"
          "  --to   <int>         Last scalar j in [from, to) (exclusive)\n"
          "\n"
          "Optional:\n"
          "  --cache-points       Persist X-coords to disk (find byte-compat)\n"
          "  --batch-size <n>     Points per batch normalisation (default 32)\n"
          "  --variants <n>       Number of variants: 256 or 512 (default 512)\n"
          "  --anchor-interval <k>  Anchors every 2^k threadgroups (default 16)\n"
          "  --gpu <idx|all>      Use GPU index, or all (default all)\n"
          "  --resume             Resume from last checkpoint\n"
          "  --output-dir <dir>   Output directory (default ./greedyfind-out)\n"
          "  --log-dir <dir>      Log directory (default ./greedyfind-out)\n"
          "\n"
          "See plan.md for the full atomic unit plan and locked design "
          "decisions.\n",
          progname);
}

// Factory: pick the right GRDSweeper implementation by mode.
static id<GRDSweeper> _Nullable grd_make_sweeper(GRDMode mode) {
  if (mode == GRDModePubkey) {
    return [[GRDPubkeySweeper alloc] init];
  } else if (mode == GRDModeAddress) {
    return [[GRDAddressSweeper alloc] init];
  }
  return nil;
}

int GRDRunSession(int argc, const char *_Nonnull *_Nonnull argv) {
  if (argc < 2) {
    PrintUsage(argv[0]);
    return 0;
  }
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
      PrintUsage(argv[0]);
      return 0;
    }
    if (strcmp(argv[i], "--version") == 0) {
      printf("greedyfind v0.1.0\n");
      return 0;
    }
  }

  NSError *err = nil;
  GRDOptions *opts = GRDOptionsFromArgv(argc, argv, &err);
  if (!opts) {
    if (err) {
      fprintf(stderr, "grd: %s\n",
              [[err localizedDescription] UTF8String]);
    } else {
      fprintf(stderr, "grd: argument parse failed\n");
    }
    return 64;
  }

  // Metal-only dispatch. The sweeper enumerates every Metal device
  // (MTLCopyAllDevices), opens one command queue per device, and
  // issues pipelined command buffers across the full GPU pool. The
  // CPU is reserved for the small amount of host-side prep work
  // (variant upload, target upload, anchor precompute) which runs
  // on a concurrent dispatch queue.
  id<GRDSweeper> sweeper = grd_make_sweeper(opts->mode);
  if (!sweeper) {
    fprintf(stderr, "grd: no sweeper available for mode\n");
    GRDOptionsFree(opts);
    return 70;
  }
  NSError *setup_err = nil;
  if (![sweeper setupWithOptions:opts error:&setup_err]) {
    fprintf(stderr, "grd: setup failed: %s\n",
            setup_err ? [[setup_err localizedDescription] UTF8String]
                       : "(no error)");
    GRDOptionsFree(opts);
    return 70;
  }
  __block int exit_code = 0;
  [sweeper executeWithCompletion:^(NSArray<GRDMatch *> *_Nullable matches,
                                    NSError *_Nullable runErr) {
    if (runErr) {
      fprintf(stderr, "grd: sweep failed: %s\n",
              [[runErr localizedDescription] UTF8String]);
      exit_code = 70;
    } else if (matches) {
      for (GRDMatch *m in matches) {
        printf("%s\n", [[m description] UTF8String]);
      }
    }
  }];
  GRDOptionsFree(opts);
  return exit_code;
}

NS_ASSUME_NONNULL_END
