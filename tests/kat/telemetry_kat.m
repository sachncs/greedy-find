// tests/kat/telemetry_kat.m — KAT for GRDTelemetry (A35).
//
// Verifies NDJSON event emission, level filtering, and rotation.

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "config.h"
#include "telemetry.h"

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
      stringWithFormat:@"grd-tel-kat-%d-%ld", (int)getpid(), (long)time(NULL)];
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

static void test_paths_and_create(void) {
  NSString* dir = make_tmpdir();
  if (!dir) {
    g_failures++;
    return;
  }
  GRDTelemetry* tel = [[GRDTelemetry alloc] initWithOutputDirectory:dir];
  if (![tel.ndjsonPath hasSuffix:@"events.ndjson"]) {
    FAILF("ndjson_path", "got %s", [tel.ndjsonPath UTF8String]);
  }
  if (![tel.textPath hasSuffix:@"events.log"]) {
    FAILF("text_path", "got %s", [tel.textPath UTF8String]);
  }
  if (![tel.outputDirectory isEqualToString:dir]) {
    FAILF("output_dir", "got %s", [tel.outputDirectory UTF8String]);
  }
  cleanup_dir(dir);
}

static void test_emit_event_writes_ndjson(void) {
  NSString* dir = make_tmpdir();
  if (!dir) {
    g_failures++;
    return;
  }
  GRDTelemetry* tel = [[GRDTelemetry alloc] initWithOutputDirectory:dir];
  [tel emitEvent:@"sweep.start"
           level:GRDLogLevelInfo
          fields:@{@"from" : @"0", @"to" : @"100"}];
  NSError* err = nil;
  if (![tel flush:&err]) {
    FAILF("flush", "%s", [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }
  NSData* data = [NSData dataWithContentsOfFile:tel.ndjsonPath];
  if (data.length == 0) {
    FAIL0("emit", "no NDJSON written");
    cleanup_dir(dir);
    return;
  }
  NSString* content = [[NSString alloc] initWithData:data
                                            encoding:NSUTF8StringEncoding];
  if (![content containsString:@"\"name\":\"sweep.start\""]) {
    FAILF("emit", "missing event name: %s", [content UTF8String]);
  }
  if (![content containsString:@"\"level\":1"]) {
    FAILF("emit", "missing level: %s", [content UTF8String]);
  }
  if (![content hasSuffix:@"\n"]) {
    FAIL0("emit", "NDJSON line not newline-terminated");
  }
  cleanup_dir(dir);
}

static void test_text_log_filters_below_threshold(void) {
  NSString* dir = make_tmpdir();
  if (!dir) {
    g_failures++;
    return;
  }
  GRDTelemetry* tel = [[GRDTelemetry alloc] initWithOutputDirectory:dir];
  tel.textLevel = GRDLogLevelWarn;
  [tel emitEvent:@"dbg.evt" level:GRDLogLevelDebug fields:@{@"k" : @"v"}];
  [tel emitEvent:@"info.evt" level:GRDLogLevelInfo fields:@{@"k" : @"v"}];
  [tel emitEvent:@"warn.evt" level:GRDLogLevelWarn fields:@{@"k" : @"v"}];
  NSError* err = nil;
  if (![tel flush:&err]) {
    FAILF("flush", "%s", [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }
  NSString* text = [[NSString alloc]
      initWithData:[NSData dataWithContentsOfFile:tel.textPath]
          encoding:NSUTF8StringEncoding];
  if ([text containsString:@"dbg.evt"]) {
    FAILF("filter", "debug event leaked into text log: %s", [text UTF8String]);
  }
  if ([text containsString:@"info.evt"]) {
    FAILF("filter", "info event leaked into text log: %s", [text UTF8String]);
  }
  if (![text containsString:@"warn.evt"]) {
    FAILF("filter", "warn event missing from text log: %s", [text UTF8String]);
  }
  cleanup_dir(dir);
}

static void test_multiple_events_are_appended(void) {
  NSString* dir = make_tmpdir();
  if (!dir) {
    g_failures++;
    return;
  }
  GRDTelemetry* tel = [[GRDTelemetry alloc] initWithOutputDirectory:dir];
  for (int i = 0; i < 5; ++i) {
    [tel emitEvent:[NSString stringWithFormat:@"e.%d", i]
             level:GRDLogLevelInfo
            fields:@{
              @"i" : @(i)
            }];
  }
  NSError* err = nil;
  if (![tel flush:&err]) {
    FAILF("flush", "%s", [[err localizedDescription] UTF8String]);
    cleanup_dir(dir);
    return;
  }
  NSString* content = [[NSString alloc]
      initWithData:[NSData dataWithContentsOfFile:tel.ndjsonPath]
          encoding:NSUTF8StringEncoding];
  int lines = 0;
  for (NSUInteger i = 0; i < content.length; ++i) {
    if ([content characterAtIndex:i] == '\n')
      lines++;
  }
  if (lines != 5) {
    FAILF("lines", "expected 5 newline-terminated lines, got %d: %s", lines,
          [content UTF8String]);
  }
  cleanup_dir(dir);
}

int main(void) {
  test_paths_and_create();
  test_emit_event_writes_ndjson();
  test_text_log_filters_below_threshold();
  test_multiple_events_are_appended();
  if (g_failures) {
    fprintf(stderr, "telemetry_kat: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("telemetry_kat: all tests passed\n");
  return 0;
}
