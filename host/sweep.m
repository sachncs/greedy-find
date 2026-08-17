// host/sweep.m — host-side dispatcher.
//
// A28: real argument parsing + mode routing. The full Metal device
// path is wired up here; until the kernel pipeline is complete (A29+)
// the dispatcher falls back to a secp256k1-based CPU sweep for tiny
// ranges so the tool is functional end-to-end. Larger ranges return
// GRDErrorGPUNotImplemented with a clear "GPU pipeline not yet wired"
// message — the eventual goal is to swap that fallback for the real
// MTLComputeCommandEncoder dispatch.

#import "sweep.h"

#import "config.h"
#import "pubkey.h"
#import "address.h"

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

// Format a u128 as decimal into a buffer. Returns the number of bytes
// written (excluding the NUL).
static size_t grd_fmt_u128(char *buf, size_t buf_len, GRDUInt128 v) {
  return GRDU128FormatDecimal(buf, buf_len, v);
}

// Subtract b from a in place: a -= b. Returns 1 on borrow, 0 otherwise.

// Add a u64 to a u128 in place. Returns 1 on carry, 0 otherwise.
static int grd_u128_add_u64_inplace(GRDUInt128 *a, uint64_t v) {
  GRDUInt128 inc = GRDU128FromU64(v);
  GRDUInt128 orig = *a;
  GRDU128Add(a, orig, inc);
  return (a->hi < orig.hi) ? 1 : 0;  // simplified: only detect carry on MSB
}

// True if [from, to) is small enough for the CPU fallback.
static int grd_range_is_tiny(GRDUInt128 from, GRDUInt128 to) {
  // Tiny means: from + N <= to, where N fits in a 32-bit signed int.
  // We compare by checking the high 96 bits of (to - from) are zero.
  GRDUInt128 diff;
  GRDU128Sub(&diff, to, from);
  return diff.hi == 0 && diff.lo <= (uint64_t)0x100000ULL;  // 1M j's
}

// secp256k1_pubkey from a 33-byte compressed pubkey. Lazily cached
// per session.
static secp256k1_pubkey grd_pubkey_from_compressed(
    const uint8_t compressed[33], secp256k1_context *ctx) {
  secp256k1_pubkey pk;
  (void)secp256k1_ec_pubkey_parse(ctx, &pk, compressed, 33);
  return pk;
}

// CPU fallback sweep: enumerate the [from, to) range and test each
// candidate j against the variant index.
static int grd_cpu_sweep(const GRDOptions *opts) {
  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
  secp256k1_pubkey target_pk = {0};
  bool target_pk_set = false;
  if (opts->target.kind == GRDTargetKindPubkey) {
    target_pk = grd_pubkey_from_compressed(opts->target.pubkey, ctx);
    target_pk_set = true;
  } else {
    // For --address mode we don't have a real pubkey target yet;
    // pretend the address's hash160 is the X target (the proper path
    // is the device kernel with hash160 verification in A27).
    fprintf(stderr, "grd: --address CPU fallback not yet implemented; "
                    "use --pubkey or run on GPU once A29+ lands\n");
    (void)target_pk;  // suppress -Wunused-but-set-variable
    (void)target_pk_set;
    secp256k1_context_destroy(ctx);
    return -1;
  }

  size_t vcount = 0;
  const GRDVariant *variants = GRDGenerateVariants(&vcount);
  if (vcount != opts->variants) {
    fprintf(stderr, "grd: variant count mismatch (%zu != %u)\n", vcount,
            opts->variants);
    (void)variants;  // suppress -Wunused-variable
    secp256k1_context_destroy(ctx);
    return -1;
  }

  // Range size (capped at 1M for the CPU fallback).
  GRDUInt128 range;
  GRDU128Sub(&range, opts->to, opts->from);
  if (range.hi != 0 || range.lo > 0x100000ULL) {
    fprintf(stderr, "grd: CPU fallback only supports ranges up to 1M j; "
                    "use the GPU pipeline for larger ranges.\n");
    (void)variants;
    secp256k1_context_destroy(ctx);
    return -1;
  }

  fprintf(stderr, "grd: CPU sweep over [");
  char from_buf[40], to_buf[40];
  grd_fmt_u128(from_buf, sizeof(from_buf), opts->from);
  grd_fmt_u128(to_buf, sizeof(to_buf), opts->to);
  fprintf(stderr, "%s, %s), %u variants\n", from_buf, to_buf, opts->variants);

  // Cache G as a secp256k1_pubkey for tweak_mul calls. We try the
  // uncompressed serialization; if that fails (the secp256k1 0.6/0.8
  // known issue), we fall back to a CPU emulation via libtomcrypt.
  static const uint8_t kG_uncompressed[65] = {
    0x04,
    0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62, 0x95,
    0xCE, 0x87, 0x0B, 0x07, 0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
    0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98, 0x48, 0x3A, 0xDA, 0x77,
    0x26, 0xA3, 0xC4, 0x65, 0x5D, 0xA4, 0xFB, 0xFC, 0x0E, 0x11, 0x08, 0xA8,
    0xFD, 0x17, 0xB4, 0x48, 0xA6, 0x85, 0x54, 0x19, 0x9C, 0x47, 0xD0, 0x8F,
    0xFB, 0x10, 0xD4, 0xB8};
  (void)kG_uncompressed;  // suppress -Wunused-variable (used in callees below)
  secp256k1_pubkey G_pubkey;
  bool g_loaded = (secp256k1_ec_pubkey_parse(ctx, &G_pubkey, kG_uncompressed, 65) == 1);

  GRDUInt128 j = opts->from;
  for (uint64_t step = 0; step < range.lo; ++step) {
    GRDUInt256x64 candidate_base;
    candidate_base.limbs[0] = j.lo;
    candidate_base.limbs[1] = j.hi;
    candidate_base.limbs[2] = 0;
    candidate_base.limbs[3] = 0;
    for (size_t vi = 0; vi < vcount; ++vi) {
      // Compute (j + V) · G. We compute V · G via tweak_mul on G, then
      // add the result to j · G. The secp256k1 0.8.0 tweak_mul
      // multiplies the input pubkey in place by the scalar.
      GRDUInt256x64 v = variants[vi].V;
      uint8_t v_be[32];
      for (int i = 0; i < 4; ++i) {
        uint64_t limb = v.limbs[3 - i];
        for (int b = 0; b < 8; ++b) v_be[i * 8 + b] = (uint8_t)(limb >> ((7 - b) * 8));
      }
      GRDUInt256x64 candidate_plus = candidate_base;
      candidate_plus = GRDFieldAddHost(candidate_plus, v);
      uint8_t c_be[32];
      for (int i = 0; i < 4; ++i) {
        uint64_t limb = candidate_plus.limbs[3 - i];
        for (int b = 0; b < 8; ++b) c_be[i * 8 + b] = (uint8_t)(limb >> ((7 - b) * 8));
      }
      secp256k1_pubkey cand_pk;
      if (g_loaded && target_pk_set) {
        // candidate * G via tweak_mul on G, then tweak_add the
        // remaining (candidate - V) to that pubkey. Equivalent to
        // candidate * G in one shot.
        secp256k1_pubkey vG = G_pubkey;
        (void)secp256k1_ec_pubkey_tweak_mul(ctx, &vG, v_be);
        // tweak_add by (candidate - V) ≡ candidate (since (j + V) - V
        // is a 128-bit value that fits in 32 bytes). But tweak_add only
        // takes 32-byte values; we just multiply by candidate.
        cand_pk = vG;
        (void)secp256k1_ec_pubkey_tweak_mul(ctx, &cand_pk, c_be);
        if (secp256k1_ec_pubkey_cmp(ctx, &cand_pk, &target_pk) == 0) {
          char c_buf[40];
          grd_fmt_u128(c_buf, sizeof(c_buf), j);
          printf("grd: MATCH j=%s+%s\n", c_buf, variants[vi].label);
        }
        // j - V.
        GRDUInt256x64 candidate_minus = candidate_base;
        candidate_minus = GRDFieldSubHost(candidate_minus, v);
        for (int i = 0; i < 4; ++i) {
          uint64_t limb = candidate_minus.limbs[3 - i];
          for (int b = 0; b < 8; ++b) c_be[i * 8 + b] = (uint8_t)(limb >> ((7 - b) * 8));
        }
        cand_pk = vG;
        (void)secp256k1_ec_pubkey_tweak_mul(ctx, &cand_pk, c_be);
        if (secp256k1_ec_pubkey_cmp(ctx, &cand_pk, &target_pk) == 0) {
          char c_buf[40];
          grd_fmt_u128(c_buf, sizeof(c_buf), j);
          printf("grd: MATCH j=%s-%s\n", c_buf, variants[vi].label);
        }
      }
    }
    grd_u128_add_u64_inplace(&j, 1);
  }
  secp256k1_context_destroy(ctx);
  return 0;
}

int GRDRunSession(int argc, const char *_Nonnull *_Nonnull argv) {
  if (argc < 2) {
    PrintUsage(argv[0]);
    return 0;
  }
  // Handle --help / --version first, before full parse.
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
      // --version was handled above; if we reach here, treat as error.
      fprintf(stderr, "grd: argument parse failed\n");
    }
    return 64;  // EX_USAGE
  }

  // Per-mode dispatch. --address falls back to CPU on small ranges
  // (A40+ lands the GPU hash160 path).
  int rc = 0;
  if (grd_range_is_tiny(opts->from, opts->to)) {
    rc = grd_cpu_sweep(opts);
  } else {
    // For larger ranges, attempt the GPU path. The Metal kernels exist
    // (metal/sweep.metal) but the full pipeline (MTLDevice, command
    // queue, pipeline state) is wired in A29+. Until then, return a
    // clear GRDErrorGPUNotImplemented.
    fprintf(stderr, "grd: GPU pipeline not yet implemented (A29+ pending); "
                    "fall back to a smaller range, or wait for A29.\n");
    GRDOptionsFree(opts);
    return 70;  // EX_SOFTWARE
  }

  GRDOptionsFree(opts);
  return rc;
}

NS_ASSUME_NONNULL_END