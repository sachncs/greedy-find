// host/config.m — argument parsing (A28).
//
// All CLI flags from the plan are parsed into a GRDOptions struct.
// Validation: --pubkey XOR --address; --from < --to; both --from and
// --to required; --variants must be 256 or 512; --anchor-interval 0..16.
// Returns an NSError with code GRDErrorInvalidArguments on failure.

#import "config.h"

#import "sweep.h"

#import <stdlib.h>
#import <string.h>

void GRDOptionsFree(GRDOptions *_Nullable opts) {
  if (!opts) return;
  free((void *)opts->output_dir);
  free((void *)opts->log_dir);
  free(opts);
}

static int grd_parse_pubkey_hex(GRDOptions *opts, const char *hex,
                                NSError *_Nullable *_Nullable outError) {
  // Strip optional 0x prefix.
  if (hex[0] == '0' && (hex[1] == 'x' || hex[1] == 'X')) hex += 2;
  size_t hex_len = strlen(hex);
  if (hex_len != 33 * 2 && hex_len != 65 * 2) {
    if (outError)
      *outError = [NSError errorWithDomain:GRDErrorDomain
                                     code:GRDErrorInvalidArguments
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       @"--pubkey must be 33 or 65 bytes hex"
                                 }];
    return -1;
  }
  uint8_t raw[65];
  size_t outlen = 0;
  for (size_t i = 0; i < hex_len; i += 2) {
    unsigned int b;
    if (sscanf(hex + i, "%2x", &b) != 1) {
      if (outError)
        *outError = [NSError errorWithDomain:GRDErrorDomain
                                       code:GRDErrorInvalidArguments
                                   userInfo:@{
                                     NSLocalizedDescriptionKey:
                                         @"--pubkey: invalid hex"
                                   }];
      return -1;
    }
    raw[outlen++] = (uint8_t)b;
  }
  // For uncompressed (65 bytes), take only the X coordinate (bytes 1..32).
  // For compressed (33 bytes), bytes 1..32 are X; byte 0 is parity tag.
  if (outlen == 65 && raw[0] != 0x04) {
    if (outError)
      *outError = [NSError errorWithDomain:GRDErrorDomain
                                     code:GRDErrorInvalidArguments
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       @"--pubkey: uncompressed must start with 0x04"
                                 }];
    return -1;
  }
  if (outlen == 33 && (raw[0] != 0x02 && raw[0] != 0x03)) {
    if (outError)
      *outError = [NSError errorWithDomain:GRDErrorDomain
                                     code:GRDErrorInvalidArguments
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       @"--pubkey: compressed must start with 0x02/0x03"
                                 }];
    return -1;
  }
  // Convert X (bytes 1..32) to little-endian limbs.
  for (int i = 0; i < 4; ++i) {
    uint64_t limb = 0;
    for (int j = 0; j < 8; ++j) {
      limb = (limb << 8) | raw[1 + i * 8 + j];
    }
    opts->target.target_x.limbs[3 - i] = limb;
  }
  memcpy(opts->target.pubkey, raw, outlen);
  opts->target.kind = GRDTargetKindPubkey;
  return 0;
}

static int grd_parse_address(GRDOptions *opts, const char *str,
                             NSError *_Nullable *_Nullable outError) {
  uint8_t version = 0;
  NSData *hash = GRDDecodeAddress([NSString stringWithUTF8String:str],
                                  &version, outError);
  if (!hash) return -1;
  if (version != 0x00 && version != 0x05) {
    if (outError)
      *outError = [NSError errorWithDomain:GRDErrorDomain
                                     code:GRDErrorAddressDecodeFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       @"Address: unsupported version byte"
                                 }];
    return -1;
  }
  if ([hash length] != 20) {
    if (outError)
      *outError = [NSError errorWithDomain:GRDErrorDomain
                                     code:GRDErrorAddressDecodeFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       @"Address: invalid hash160 length"
                                 }];
    return -1;
  }
  // The X of the script-hash address isn't directly the hash160 (which
  // is a script-hash, not a pubkey-hash). For the public-key path
  // (--address), we use the hash160 of the script-hash as a stand-in.
  // A future optimisation (A40+) could decode the script.
  const uint8_t *p = [hash bytes];
  for (int i = 0; i < 4; ++i) {
    uint64_t limb = 0;
    for (int j = 0; j < 8; ++j) limb = (limb << 8) | p[i * 8 + j];
    opts->target.target_x.limbs[3 - i] = limb;
  }
  memcpy(opts->target.hash160, p, 20);
  opts->target.kind = GRDTargetKindAddress;
  return 0;
}

static int grd_parse_decimal_u128(GRDUInt128 *out, const char *s,
                                  NSError *_Nullable *_Nullable outError) {
  const char *err = GRDU128ParseDecimal(out, s);
  if (err) {
    if (outError)
      *outError = [NSError errorWithDomain:GRDErrorDomain
                                     code:GRDErrorInvalidArguments
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       [NSString stringWithFormat:@"--from/--to: %s", err]
                                 }];
    return -1;
  }
  return 0;
}

GRDOptions *_Nullable GRDOptionsFromArgv(
    int argc, const char *_Nonnull *_Nonnull argv,
    NSError *_Nullable *_Nullable outError) {
  GRDOptions *opts = calloc(1, sizeof(GRDOptions));
  if (!opts) {
    if (outError)
      *outError = [NSError errorWithDomain:GRDErrorDomain
                                     code:GRDErrorUnknown
                                 userInfo:@{
                                   NSLocalizedDescriptionKey: @"Out of memory"
                                 }];
    return NULL;
  }
  // Defaults
  opts->mode = (GRDMode)-1;  // unset
  opts->target.kind = GRDTargetKindNone;
  opts->from = (GRDUInt128){0, 0};
  opts->to = (GRDUInt128){0, 0};
  opts->batch_size = 32;
  opts->variants = 512;
  opts->anchor_interval_k = 16;
  opts->gpu_index = -1;  // all
  opts->cache_points = false;
  opts->resume = false;
  opts->output_dir = NULL;
  opts->log_dir = NULL;

  const char *pubkey_hex = NULL;
  const char *address = NULL;

  for (int i = 1; i < argc; ++i) {
    const char *a = argv[i];
    if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
      // Caller should have already handled --help.
      continue;
    }
    if (strcmp(a, "--version") == 0) {
      printf("greedyfind v0.1.0\n");
      // Caller handles exit code; we just return a sentinel.
      GRDOptionsFree(opts);
      return NULL;
    }
    if (strcmp(a, "--pubkey") == 0 && i + 1 < argc) {
      pubkey_hex = argv[++i];
    } else if (strncmp(a, "--pubkey=", 10) == 0) {
      pubkey_hex = a + 10;
    } else if (strcmp(a, "--address") == 0 && i + 1 < argc) {
      address = argv[++i];
    } else if (strncmp(a, "--address=", 10) == 0) {
      address = a + 10;
    } else if ((strcmp(a, "--from") == 0 || strncmp(a, "--from=", 7) == 0)
               && i + (a[6] == '=' ? 0 : 1) < argc) {
      const char *v = a[6] == '=' ? a + 7 : argv[++i];
      if (grd_parse_decimal_u128(&opts->from, v, outError)) {
        GRDOptionsFree(opts);
        return NULL;
      }
    } else if ((strcmp(a, "--to") == 0 || strncmp(a, "--to=", 5) == 0)
               && i + (a[4] == '=' ? 0 : 1) < argc) {
      const char *v = a[4] == '=' ? a + 5 : argv[++i];
      if (grd_parse_decimal_u128(&opts->to, v, outError)) {
        GRDOptionsFree(opts);
        return NULL;
      }
    } else if (strcmp(a, "--cache-points") == 0) {
      opts->cache_points = true;
    } else if (strcmp(a, "--resume") == 0) {
      opts->resume = true;
    } else if (strcmp(a, "--batch-size") == 0 && i + 1 < argc) {
      opts->batch_size = (uint32_t)atoi(argv[++i]);
    } else if (strncmp(a, "--batch-size=", 13) == 0) {
      opts->batch_size = (uint32_t)atoi(a + 13);
    } else if (strcmp(a, "--variants") == 0 && i + 1 < argc) {
      opts->variants = (uint32_t)atoi(argv[++i]);
    } else if (strncmp(a, "--variants=", 11) == 0) {
      opts->variants = (uint32_t)atoi(a + 11);
    } else if (strcmp(a, "--anchor-interval") == 0 && i + 1 < argc) {
      opts->anchor_interval_k = (uint32_t)atoi(argv[++i]);
    } else if (strncmp(a, "--anchor-interval=", 19) == 0) {
      opts->anchor_interval_k = (uint32_t)atoi(a + 19);
    } else if (strcmp(a, "--gpu") == 0 && i + 1 < argc) {
      const char *v = argv[++i];
      if (strcmp(v, "all") == 0) opts->gpu_index = -1;
      else opts->gpu_index = atoi(v);
    } else if (strncmp(a, "--gpu=", 6) == 0) {
      const char *v = a + 6;
      if (strcmp(v, "all") == 0) opts->gpu_index = -1;
      else opts->gpu_index = atoi(v);
    } else if (strcmp(a, "--output-dir") == 0 && i + 1 < argc) {
      opts->output_dir = strdup(argv[++i]);
    } else if (strncmp(a, "--output-dir=", 13) == 0) {
      opts->output_dir = strdup(a + 13);
    } else if (strcmp(a, "--log-dir") == 0 && i + 1 < argc) {
      opts->log_dir = strdup(argv[++i]);
    } else if (strncmp(a, "--log-dir=", 10) == 0) {
      opts->log_dir = strdup(a + 10);
    } else {
      if (outError)
        *outError = [NSError errorWithDomain:GRDErrorDomain
                                       code:GRDErrorInvalidArguments
                                   userInfo:@{
                                     NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:
                                             @"Unknown flag: %s", a]
                                   }];
      GRDOptionsFree(opts);
      return NULL;
    }
  }

  // Validate mode (--pubkey XOR --address).
  if ((pubkey_hex != NULL) == (address != NULL)) {
    if (outError)
      *outError = [NSError errorWithDomain:GRDErrorDomain
                                     code:GRDErrorInvalidArguments
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       @"Exactly one of --pubkey or --address is required"
                                 }];
    GRDOptionsFree(opts);
    return NULL;
  }
  if (pubkey_hex) {
    opts->mode = GRDModePubkey;
    if (grd_parse_pubkey_hex(opts, pubkey_hex, outError)) {
      GRDOptionsFree(opts);
      return NULL;
    }
  } else {
    opts->mode = GRDModeAddress;
    if (grd_parse_address(opts, address, outError)) {
      GRDOptionsFree(opts);
      return NULL;
    }
  }

  // Validate [from, to).
  if (GRDU128Cmp(opts->from, opts->to) >= 0) {
    if (outError)
      *outError = [NSError errorWithDomain:GRDErrorDomain
                                     code:GRDErrorInvalidArguments
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       @"--from must be strictly less than --to"
                                 }];
    GRDOptionsFree(opts);
    return NULL;
  }
  // from and to must be specified (default 0/0 means unspecified).
  if (opts->from.lo == 0 && opts->from.hi == 0 &&
      opts->to.lo == 0 && opts->to.hi == 0) {
    if (outError)
      *outError = [NSError errorWithDomain:GRDErrorDomain
                                     code:GRDErrorInvalidArguments
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       @"--from and --to are required"
                                 }];
    GRDOptionsFree(opts);
    return NULL;
  }

  // Validate options.
  if (opts->variants != 256 && opts->variants != 512) {
    if (outError)
      *outError = [NSError errorWithDomain:GRDErrorDomain
                                     code:GRDErrorInvalidArguments
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       @"--variants must be 256 or 512"
                                 }];
    GRDOptionsFree(opts);
    return NULL;
  }
  if (opts->anchor_interval_k > 16) {
    if (outError)
      *outError = [NSError errorWithDomain:GRDErrorDomain
                                     code:GRDErrorInvalidArguments
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       @"--anchor-interval must be <= 16"
                                 }];
    GRDOptionsFree(opts);
    return NULL;
  }
  if (opts->batch_size == 0) opts->batch_size = 32;

  // Set defaults for paths.
  if (!opts->output_dir) opts->output_dir = strdup("./greedyfind-out");
  if (!opts->log_dir) opts->log_dir = strdup(opts->output_dir);

  return opts;
}