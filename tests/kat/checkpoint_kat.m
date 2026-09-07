// tests/kat/checkpoint_kat.m — KAT for atomic checkpoint (A34).
//
// Verifies save→load round-trip, write-then-rename durability, and
// integrity-hash tamper detection for GRDCheckpointStore.

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "checkpoint.h"
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
  NSString* name = [NSString
      stringWithFormat:@"grd-ckpt-kat-%d-%ld", (int)getpid(), (long)time(NULL)];
  NSString* path = [base stringByAppendingPathComponent:name];
  NSError* err = nil;
  if (![[NSFileManager defaultManager] createDirectoryAtPath:path
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&err]) {
    fprintf(stderr, "FAIL [setup] cannot create %s: %s\n", [path UTF8String],
            [[err localizedDescription] UTF8String]);
    return nil;
  }
  return path;
}

static void cleanup_dir(NSString* path) {
  [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void test_save_load_round_trip(void) {
  NSString* dir = make_tmpdir();
  if (!dir) {
    g_failures++;
    return;
  }

  GRDCheckpointStore* store =
      [[GRDCheckpointStore alloc] initWithOutputDirectory:dir];
  GRDUInt128 j = {.lo = 0x0123456789abcdefULL, .hi = 0xfedcba9876543210ULL};
  GRDCheckpoint* cp = [[GRDCheckpoint alloc] initWithNextJ:j
                                          targetDescriptor:@"puzzle-71"];

  NSError* err = nil;
  if (![store saveCheckpoint:cp error:&err]) {
    FAILF("save", "saveCheckpoint failed: %s",
          [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }

  GRDCheckpoint* loaded = [store loadCheckpointForDescriptor:@"puzzle-71"
                                                       error:&err];
  if (!loaded) {
    FAILF("load", "loadCheckpoint failed: %s",
          [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }
  if (loaded.next_j.lo != j.lo || loaded.next_j.hi != j.hi) {
    FAILF("round_trip", "next_j mismatch: got (%llx, %llx), want (%llx, %llx)",
          loaded.next_j.lo, loaded.next_j.hi, j.lo, j.hi);
  }
  if (![loaded.targetDescriptor isEqualToString:@"puzzle-71"]) {
    FAILF("round_trip", "targetDescriptor: got %s, want puzzle-71",
          [loaded.targetDescriptor UTF8String]);
  }

  cleanup_dir(dir);
}

static void test_separate_descriptors(void) {
  NSString* dir = make_tmpdir();
  if (!dir) {
    g_failures++;
    return;
  }

  GRDCheckpointStore* store =
      [[GRDCheckpointStore alloc] initWithOutputDirectory:dir];

  GRDCheckpoint* a =
      [[GRDCheckpoint alloc] initWithNextJ:(GRDUInt128){.lo = 1, .hi = 0}
                          targetDescriptor:@"target-A"];
  GRDCheckpoint* b = [[GRDCheckpoint alloc]
         initWithNextJ:(GRDUInt128){.lo = 0xdead, .hi = 0xbeef}
      targetDescriptor:@"target-B"];

  NSError* err = nil;
  if (![store saveCheckpoint:a error:&err]) {
    FAILF("save_A", "%s", [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }
  if (![store saveCheckpoint:b error:&err]) {
    FAILF("save_B", "%s", [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }

  GRDCheckpoint* la = [store loadCheckpointForDescriptor:@"target-A"
                                                   error:&err];
  GRDCheckpoint* lb = [store loadCheckpointForDescriptor:@"target-B"
                                                   error:&err];
  if (!la || !lb) {
    FAIL0("separate", "load returned nil");
    cleanup_dir(dir);
    return;
  }
  if (la.next_j.lo != 1 || la.next_j.hi != 0) {
    FAILF("separate_A", "next_j lo mismatch: got %llx, want 1", la.next_j.lo);
  }
  if (lb.next_j.lo != 0xdead || lb.next_j.hi != 0xbeef) {
    FAILF("separate_B", "next_j mismatch: got (%llx, %llx)", lb.next_j.lo,
          lb.next_j.hi);
  }

  cleanup_dir(dir);
}

static void test_clean_start(void) {
  NSString* dir = make_tmpdir();
  if (!dir) {
    g_failures++;
    return;
  }

  GRDCheckpointStore* store =
      [[GRDCheckpointStore alloc] initWithOutputDirectory:dir];

  // No checkpoint saved — load should return nil with no error.
  NSError* err = nil;
  GRDCheckpoint* missing = [store loadCheckpointForDescriptor:@"no-such-target"
                                                        error:&err];
  if (missing != nil) {
    FAIL0("clean_start", "expected nil for missing checkpoint");
  }
  if (err != nil) {
    FAILF("clean_start", "expected no error, got: %s",
          [[err localizedDescription] UTF8String]);
  }
  cleanup_dir(dir);
}

static void test_overwrite_is_atomic(void) {
  NSString* dir = make_tmpdir();
  if (!dir) {
    g_failures++;
    return;
  }

  GRDCheckpointStore* store =
      [[GRDCheckpointStore alloc] initWithOutputDirectory:dir];

  GRDUInt128 j1 = {.lo = 0xaaaa, .hi = 0};
  GRDUInt128 j2 = {.lo = 0xbbbb, .hi = 0};
  GRDCheckpoint* cp1 = [[GRDCheckpoint alloc] initWithNextJ:j1
                                           targetDescriptor:@"t"];
  GRDCheckpoint* cp2 = [[GRDCheckpoint alloc] initWithNextJ:j2
                                           targetDescriptor:@"t"];

  NSError* err = nil;
  if (![store saveCheckpoint:cp1 error:&err] || ![store saveCheckpoint:cp2
                                                                 error:&err]) {
    FAILF("overwrite", "save failed: %s",
          [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }

  // After two writes, no stale .tmp should remain.
  NSString* target = [dir stringByAppendingPathComponent:@"t.ckpt"];
  NSString* stale = [dir stringByAppendingPathComponent:@"t.ckpt.tmp"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:stale]) {
    FAIL0("atomic_rename", "stale .tmp file remained after second save");
  }
  if (![[NSFileManager defaultManager] fileExistsAtPath:target]) {
    FAIL0("atomic_rename", "expected final checkpoint file missing");
  }

  GRDCheckpoint* loaded = [store loadCheckpointForDescriptor:@"t" error:&err];
  if (!loaded) {
    FAILF("overwrite_load", "load failed: %s",
          [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }
  if (loaded.next_j.lo != j2.lo || loaded.next_j.hi != j2.hi) {
    FAILF("overwrite", "expected latest write (0xbbbb), got %llx",
          loaded.next_j.lo);
  }
  cleanup_dir(dir);
}

static void test_tamper_detection(void) {
  NSString* dir = make_tmpdir();
  if (!dir) {
    g_failures++;
    return;
  }

  GRDCheckpointStore* store =
      [[GRDCheckpointStore alloc] initWithOutputDirectory:dir];

  GRDCheckpoint* cp =
      [[GRDCheckpoint alloc] initWithNextJ:(GRDUInt128){.lo = 0x1234, .hi = 0}
                          targetDescriptor:@"t"];
  NSError* err = nil;
  if (![store saveCheckpoint:cp error:&err]) {
    FAILF("tamper_save", "save failed: %s",
          [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }

  // Flip a hex digit in next_j_lo to invalidate the integrity hash.
  NSString* target = [dir stringByAppendingPathComponent:@"t.ckpt"];
  NSData* data = [NSData dataWithContentsOfFile:target];
  if (data.length == 0) {
    FAIL0("tamper", "checkpoint file empty");
    cleanup_dir(dir);
    return;
  }
  NSMutableData* munged = [data mutableCopy];
  // Position of the first hex digit in next_j_lo (after "next_j_lo":").
  NSString* content = [[NSString alloc] initWithData:munged
                                            encoding:NSUTF8StringEncoding];
  NSRange r = [content rangeOfString:@"\"next_j_lo\":\""];
  if (r.location == NSNotFound) {
    FAIL0("tamper", "cannot find next_j_lo field");
    cleanup_dir(dir);
    return;
  }
  NSUInteger byte_idx = r.location + r.length;  // first hex digit
  uint8_t* bytes = munged.mutableBytes;
  if (bytes[byte_idx] == '0') {
    bytes[byte_idx] = '1';
  } else {
    bytes[byte_idx] = '0';
  }
  if (![munged writeToFile:target atomically:NO]) {
    FAIL0("tamper", "cannot rewrite checkpoint for tamper test");
    cleanup_dir(dir);
    return;
  }

  GRDCheckpoint* loaded = [store loadCheckpointForDescriptor:@"t" error:&err];
  if (loaded != nil) {
    FAIL0("tamper_detect", "load should have rejected tampered checkpoint");
  } else if (err == nil) {
    FAIL0("tamper_detect", "expected integrity-failure error");
  } else if (err.code != GRDErrorCheckpointFailed) {
    FAILF("tamper_detect", "unexpected error code: %ld", (long)err.code);
  }
  cleanup_dir(dir);
}

static void test_well_formed_json(void) {
  NSString* dir = make_tmpdir();
  if (!dir) {
    g_failures++;
    return;
  }

  GRDCheckpointStore* store =
      [[GRDCheckpointStore alloc] initWithOutputDirectory:dir];
  GRDCheckpoint* cp =
      [[GRDCheckpoint alloc] initWithNextJ:(GRDUInt128){.lo = 0x42, .hi = 0}
                          targetDescriptor:@"j"];
  NSError* err = nil;
  if (![store saveCheckpoint:cp error:&err]) {
    FAILF("json_save", "%s", [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }

  NSString* target = [dir stringByAppendingPathComponent:@"j.ckpt"];
  NSData* data = [NSData dataWithContentsOfFile:target];
  NSString* content = [[NSString alloc] initWithData:data
                                            encoding:NSUTF8StringEncoding];

  // The serialized form must be a single well-formed JSON object:
  // exactly one leading '{' and one trailing '}'.
  if ([content length] < 2 || [content characterAtIndex:0] != '{' ||
      [content characterAtIndex:[content length] - 1] != '}') {
    FAILF("json_shape", "not a well-formed object: %s", [content UTF8String]);
  }
  // No stray '}' anywhere in the middle.
  NSRange middle = NSMakeRange(1, [content length] - 2);
  if ([content rangeOfString:@"}" options:0 range:middle].location !=
      NSNotFound) {
    FAILF("json_shape", "stray '}' inside body: %s", [content UTF8String]);
  }

  cleanup_dir(dir);
}

int main(void) {
  test_save_load_round_trip();
  test_separate_descriptors();
  test_clean_start();
  test_overwrite_is_atomic();
  test_tamper_detection();
  test_well_formed_json();
  if (g_failures) {
    fprintf(stderr, "checkpoint_kat: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("checkpoint_kat: all tests passed\n");
  return 0;
}
