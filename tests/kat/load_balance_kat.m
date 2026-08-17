// tests/kat/load_balance_kat.m — KAT for GRDLoadBalancer (A44).
//
// Verifies the per-device split, throughput reporting, and
// rebalance direction (slow loses range, fast gains).

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "load_balance.h"
#include "ecc.h"

static int g_failures = 0;

#define FAIL0(label, msg)                                       \
  do {                                                          \
    fprintf(stderr, "FAIL [%s] %s\n", (label), (msg));          \
    g_failures++;                                               \
  } while (0)
#define FAILF(label, ...)                                       \
  do {                                                          \
    fprintf(stderr, "FAIL [%s] ", (label));                     \
    fprintf(stderr, __VA_ARGS__);                               \
    fprintf(stderr, "\n");                                      \
    g_failures++;                                               \
  } while (0)

static void test_equal_split(void) {
  GRDUInt128 range = {.lo = 1000, .hi = 0};
  GRDLoadBalancer *lb =
      [[GRDLoadBalancer alloc] initWithDeviceCount:4 range:range];
  for (uint32_t i = 0; i < lb.deviceCount; ++i) {
    GRDUInt128 s = [lb startForDevice:i];
    GRDUInt128 e = [lb endForDevice:i];
    if (s.hi != 0 || e.hi != 0) {
      FAILF("equal_split", "device %u: non-zero hi limb", i);
    }
  }
  // First device covers [0, 250), last covers [750, 1000).
  if ([lb startForDevice:0].lo != 0 || [lb endForDevice:0].lo != 250) {
    FAILF("equal_split", "device 0: got [%llu, %llu), want [0, 250)",
          [lb startForDevice:0].lo, [lb endForDevice:0].lo);
  }
  if ([lb startForDevice:3].lo != 750 || [lb endForDevice:3].lo != 1000) {
    FAILF("equal_split", "device 3: got [%llu, %llu), want [750, 1000)",
          [lb startForDevice:3].lo, [lb endForDevice:3].lo);
  }
}

static void test_rebalance_moves_range(void) {
  GRDUInt128 range = {.lo = 1000, .hi = 0};
  GRDLoadBalancer *lb =
      [[GRDLoadBalancer alloc] initWithDeviceCount:2 range:range];
  // Device 0 is twice as fast as device 1.
  [lb reportThroughput:2000.0 forDevice:0];
  [lb reportThroughput:1000.0 forDevice:1];
  uint64_t before_0 = [lb endForDevice:0].lo - [lb startForDevice:0].lo;
  uint64_t before_1 = [lb endForDevice:1].lo - [lb startForDevice:1].lo;
  BOOL changed = [lb rebalance];
  if (!changed) {
    FAIL0("rebalance", "expected rebalance to fire on 2x ratio");
  }
  uint64_t after_0 = [lb endForDevice:0].lo - [lb startForDevice:0].lo;
  uint64_t after_1 = [lb endForDevice:1].lo - [lb startForDevice:1].lo;
  if (after_0 <= before_0) {
    FAILF("rebalance", "device 0 should gain: before=%llu after=%llu",
          before_0, after_0);
  }
  if (after_1 >= before_1) {
    FAILF("rebalance", "device 1 should lose: before=%llu after=%llu",
          before_1, after_1);
  }
}

static void test_rebalance_within_threshold(void) {
  GRDUInt128 range = {.lo = 1000, .hi = 0};
  GRDLoadBalancer *lb =
      [[GRDLoadBalancer alloc] initWithDeviceCount:2 range:range];
  // Within 5% — no rebalance.
  [lb reportThroughput:1000.0 forDevice:0];
  [lb reportThroughput:1020.0 forDevice:1];
  if ([lb rebalance]) {
    FAIL0("threshold", "rebalance should not fire within 5% ratio");
  }
}

static void test_single_device_no_rebalance(void) {
  GRDUInt128 range = {.lo = 1000, .hi = 0};
  GRDLoadBalancer *lb =
      [[GRDLoadBalancer alloc] initWithDeviceCount:1 range:range];
  [lb reportThroughput:1000.0 forDevice:0];
  if ([lb rebalance]) {
    FAIL0("single", "single-device rebalance should be a no-op");
  }
}

int main(void) {
  test_equal_split();
  test_rebalance_moves_range();
  test_rebalance_within_threshold();
  test_single_device_no_rebalance();
  if (g_failures) {
    fprintf(stderr, "load_balance_kat: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("load_balance_kat: all tests passed\n");
  return 0;
}
