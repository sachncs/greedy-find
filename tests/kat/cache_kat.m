// tests/kat/cache_kat.m — KAT for GRDCache (A33).
//
// Verifies that the on-disk cache file written by GRDCache has the
// documented find-byte-compatible format and round-trips data.

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cache.h"
#include "ecc.h"

static int g_failures = 0;

#define FAIL0(label, msg)                              \
  do {                                                 \
    fprintf(stderr, "FAIL [%s] %s\n", (label), (msg)); \
    g_failures++;                                      \
  } while (0)
#define FAILF(label, ...)                   \
  do {                                      \
    fprintf(stderr, "FAIL [%s] ", (label)); \
    fprintf(stderr, __VA_ARGS__);           \
    fprintf(stderr, "\n");                  \
    g_failures++;                           \
  } while (0)

static NSString* _Nullable make_tmpdir(void) {
  NSString* base = NSTemporaryDirectory();
  NSString* name = [NSString stringWithFormat:@"grd-cache-kat-%d-%ld",
                                              (int)getpid(), (long)time(NULL)];
  NSString* path = [base stringByAppendingPathComponent:name];
  NSError* err = nil;
  if (![[NSFileManager defaultManager] createDirectoryAtPath:path
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&err]) {
    fprintf(stderr, "FAIL [setup] %s\n",
            [[err localizedDescription] UTF8String]);
    return nil;
  }
  return path;
}

static void cleanup_dir(NSString* path) {
  [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static GRDUInt256x64 make_target_x(uint64_t seed) {
  GRDUInt256x64 v = {0};
  v.limbs[0] = seed;
  v.limbs[1] = seed * 0xdeadbeefULL;
  v.limbs[2] = seed * 0xfeedfaceULL;
  v.limbs[3] = seed * 0x12345678ULL;
  return v;
}

static void test_set_and_read_back(void) {
  NSString* dir = make_tmpdir();
  if (!dir) {
    g_failures++;
    return;
  }

  GRDUInt256x64 tx = make_target_x(0xa1b2c3d4e5f60718ULL);
  GRDCache* cache =
      [[GRDCache alloc] initWithTargetX:tx
                                   from:(GRDUInt128){.lo = 0, .hi = 0}
                                     to:(GRDUInt128){.lo = 0x100000, .hi = 0}
                        outputDirectory:dir];

  uint8_t xs[3][32];
  for (int i = 0; i < 3; ++i) {
    for (int j = 0; j < 32; ++j) xs[i][j] = (uint8_t)((i * 31 + j) & 0xff);
  }

  NSError* err = nil;
  if (![cache setX:xs[0] forVariant:0 anchor:0 error:&err] ||
      ![cache setX:xs[1] forVariant:1 anchor:0 error:&err] ||
      ![cache setX:xs[2] forVariant:0 anchor:1 error:&err]) {
    FAILF("setX", "setX failed: %s", [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }

  NSData* r0 = [cache xForVariant:0 anchor:0 error:&err];
  NSData* r1 = [cache xForVariant:1 anchor:0 error:&err];
  NSData* r2 = [cache xForVariant:0 anchor:1 error:&err];
  if (r0.length != 32 || r1.length != 32 || r2.length != 32) {
    FAILF("read", "expected 32 bytes; got %lu, %lu, %lu",
          (unsigned long)r0.length, (unsigned long)r1.length,
          (unsigned long)r2.length);
    cleanup_dir(dir);
    return;
  }
  if (memcmp(r0.bytes, xs[0], 32) != 0) {
    FAIL0("read_v0_a0", "v0/a0 mismatch");
  }
  if (memcmp(r1.bytes, xs[1], 32) != 0) {
    FAIL0("read_v1_a0", "v1/a0 mismatch");
  }
  if (memcmp(r2.bytes, xs[2], 32) != 0) {
    FAIL0("read_v0_a1", "v0/a1 mismatch");
  }
  cleanup_dir(dir);
}

static void test_file_magic_and_round_trip(void) {
  NSString* dir = make_tmpdir();
  if (!dir) {
    g_failures++;
    return;
  }

  GRDUInt256x64 tx = make_target_x(0x1234567890abcdefULL);
  GRDCache* cache =
      [[GRDCache alloc] initWithTargetX:tx
                                   from:(GRDUInt128){.lo = 0, .hi = 0}
                                     to:(GRDUInt128){.lo = 0x100000, .hi = 0}
                        outputDirectory:dir];
  uint8_t one[32];
  memset(one, 0xab, 32);
  NSError* err = nil;
  if (![cache setX:one forVariant:0 anchor:0 error:&err]) {
    FAILF("setX", "%s", [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }
  if (![cache sync:&err]) {
    FAILF("sync", "%s", [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }

  NSString* path = [cache filePath];
  NSData* file = [NSData dataWithContentsOfFile:path];
  if (file.length < 8) {
    FAILF("file", "file too small: %lu", (unsigned long)file.length);
    cleanup_dir(dir);
    return;
  }
  const char expected[8] = {'F', 'I', 'N', 'D', '-', 'C', 'A', 'C'};
  if (memcmp(file.bytes, expected, 8) != 0) {
    FAIL0("magic", "magic bytes mismatch");
  }
  cleanup_dir(dir);
}

static void test_close_rejects_writes(void) {
  NSString* dir = make_tmpdir();
  if (!dir) {
    g_failures++;
    return;
  }

  GRDUInt256x64 tx = make_target_x(0x9999ULL);
  GRDCache* cache =
      [[GRDCache alloc] initWithTargetX:tx
                                   from:(GRDUInt128){.lo = 0, .hi = 0}
                                     to:(GRDUInt128){.lo = 0x100, .hi = 0}
                        outputDirectory:dir];
  [cache close];

  uint8_t x[32] = {0};
  NSError* err = nil;
  if ([cache setX:x forVariant:0 anchor:0 error:&err]) {
    FAIL0("close", "setX should fail after close");
  } else if (err == nil) {
    FAIL0("close", "expected error after close");
  } else if (err.code != GRDErrorCacheFailed) {
    FAILF("close", "unexpected code: %ld", (long)err.code);
  }
  cleanup_dir(dir);
}

int main(void) {
  test_set_and_read_back();
  test_file_magic_and_round_trip();
  test_close_rejects_writes();
  if (g_failures) {
    fprintf(stderr, "cache_kat: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("cache_kat: all tests passed\n");
  return 0;
}
