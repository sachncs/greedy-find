// host/sweep.m — host-side dispatcher.
//
// Stub implementation that prints a help message. Real session logic lands
// in subsequent atomic units (A29+).

#import "sweep.h"

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

int GRDRunSession(int argc, const char *_Nonnull *_Nonnull argv) {
  if (argc < 2) {
    PrintUsage(argv[0]);
    return 0;  // no-args: print help, exit 0
  }
  // Argument parsing lands in A29+. Until then we accept any flag and
  // refuse politely.
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
      PrintUsage(argv[0]);
      return 0;
    }
    if (strcmp(argv[i], "--version") == 0) {
      printf("greedyfind v0.1.0 (scaffold)\n");
      return 0;
    }
  }
  fprintf(stderr,
          "greedyfind: argument parsing not yet implemented "
          "(see plan.md units A29-A32).\n");
  return 64;  // EX_USAGE
}

NS_ASSUME_NONNULL_END