// host/telemetry.m — NDJSON telemetry + rolling text log (A35).
//
// Implementation:
//   - All events go through a serial dispatch queue, so callers can
//     fire-and-forget from any thread without locking.
//   - NDJSON path: one JSON object per line, append-only with a
//     periodic fdatasync. A "truncate at" size limit (default 64 MB)
//     renames the file to <path>.1 and starts fresh when reached.
//   - Text path: human-readable "TIMESTAMP LEVEL name: key=value ..." lines
//     using the same level filter. No truncation (logs grow slowly).

#import "telemetry.h"

#import "config.h"
#import "hash.h"

#import <fcntl.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

NS_ASSUME_NONNULL_BEGIN

@implementation GRDTelemetry {
  NSString* _outputDirectory;
  NSString* _ndjsonPath;
  NSString* _textPath;
  int _ndjson_fd;
  uint64_t _ndjsonBytes;
  dispatch_queue_t _writeQueue;
  GRDLogLevel _textLevel;
}

- (instancetype)initWithOutputDirectory:(NSString*)dir {
  if ((self = [super init])) {
    _outputDirectory = [dir copy];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    _ndjsonPath = [[dir stringByAppendingPathComponent:@"events.ndjson"] copy];
    _textPath = [[dir stringByAppendingPathComponent:@"events.log"] copy];
    _ndjson_fd = -1;
    _ndjsonBytes = 0;
    _writeQueue = dispatch_queue_create("com.greedyfind.telemetry.write",
                                        DISPATCH_QUEUE_SERIAL);
    _textLevel = GRDLogLevelInfo;
  }
  return self;
}

- (void)dealloc {
  dispatch_sync(_writeQueue, ^{
    if (_ndjson_fd >= 0) {
      fsync(_ndjson_fd);
      close(_ndjson_fd);
      _ndjson_fd = -1;
    }
  });
  [super dealloc];
}

- (NSString*)outputDirectory {
  return _outputDirectory;
}
- (NSString*)ndjsonPath {
  return _ndjsonPath;
}
- (NSString*)textPath {
  return _textPath;
}
- (GRDLogLevel)textLevel {
  __block GRDLogLevel l;
  dispatch_sync(_writeQueue, ^{
    l = _textLevel;
  });
  return l;
}
- (void)setTextLevel:(GRDLogLevel)l {
  dispatch_sync(_writeQueue, ^{
    _textLevel = l;
  });
}

- (int)openNdjsonLocked {
  if (_ndjson_fd >= 0)
    return _ndjson_fd;
  _ndjson_fd =
      open([_ndjsonPath UTF8String], O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (_ndjson_fd >= 0) {
    struct stat st;
    fstat(_ndjson_fd, &st);
    _ndjsonBytes = (uint64_t)st.st_size;
  }
  return _ndjson_fd;
}

- (void)rotateLocked {
  if (_ndjson_fd >= 0) {
    fsync(_ndjson_fd);
    close(_ndjson_fd);
    _ndjson_fd = -1;
  }
  NSString* archive = [_ndjsonPath stringByAppendingString:@".1"];
  rename([_ndjsonPath UTF8String], [archive UTF8String]);
  _ndjsonBytes = 0;
}

- (void)emitEvent:(NSString*)name
            level:(GRDLogLevel)level
           fields:(nullable NSDictionary<NSString*, id>*)fields {
  if (!name)
    return;
  NSDictionary* ef = fields ? fields : @{};
  // Build NDJSON line on the calling thread; the dict iteration is
  // simple enough that the overhead is negligible.
  NSDateFormatter* fmt = [self.class _iso8601Formatter];
  NSString* ts = [fmt stringFromDate:[NSDate date]];

  // Build a stable JSON line: keys are sorted.
  NSArray<NSString*>* keys =
      [[ef allKeys] sortedArrayUsingSelector:@selector(compare:)];
  NSMutableString* line = [NSMutableString
      stringWithFormat:@"{\"ts\":\"%@\",\"name\":\"%@\",\"level\":%ld", ts,
                       name, (long)level];
  for (NSString* k in keys) {
    id v = ef[k];
    NSString* esc_k = [self escapeJson:k];
    NSString* esc_v;
    if ([v isKindOfClass:[NSString class]]) {
      esc_v = [self escapeJson:(NSString*)v];
    } else if ([v isKindOfClass:[NSNumber class]]) {
      esc_v = [v stringValue];
    } else {
      esc_v = @"null";
    }
    [line appendFormat:@",\"%@\":%@", esc_k, esc_v];
  }
  [line appendString:@"}\n"];

  // Format the text line.
  NSString* text_line = nil;
  if (level >= [self textLevel]) {
    NSArray<NSString*>* names = @[ @"DEBUG", @"INFO", @"WARN", @"ERROR" ];
    NSString* level_str = [names objectAtIndex:(NSUInteger)level];
    text_line = [NSString stringWithFormat:@"%@ %@ %@", ts, level_str, name];
    for (NSString* k in keys) {
      text_line =
          [text_line stringByAppendingFormat:@" %@=%@", k, [ef[k] description]];
    }
    text_line = [text_line stringByAppendingString:@"\n"];
  }

  NSData* ndjson_data = [line dataUsingEncoding:NSUTF8StringEncoding];
  NSData* text_data =
      text_line ? [text_line dataUsingEncoding:NSUTF8StringEncoding] : nil;
  __block GRDLogLevel capturedLevel = level;
  (void)capturedLevel;
  dispatch_async(_writeQueue, ^{
    if ([self openNdjsonLocked] < 0)
      return;
    if (_ndjsonBytes + ndjson_data.length > (1ULL << 26)) {  // 64 MiB
      [self rotateLocked];
      if ([self openNdjsonLocked] < 0)
        return;
    }
    write(_ndjson_fd, ndjson_data.bytes, ndjson_data.length);
    _ndjsonBytes += ndjson_data.length;
    if (text_data) {
      int text_fd =
          open([_textPath UTF8String], O_WRONLY | O_CREAT | O_APPEND, 0644);
      if (text_fd >= 0) {
        write(text_fd, text_data.bytes, text_data.length);
        close(text_fd);
      }
    }
  });
}

- (BOOL)flush:(NSError* _Nullable* _Nullable)error {
  __block int rc = 0;
  dispatch_sync(_writeQueue, ^{
    if (_ndjson_fd >= 0) {
      rc = fsync(_ndjson_fd);
    }
  });
  if (rc < 0 && error) {
    *error = [NSError
        errorWithDomain:GRDErrorDomain
                   code:GRDErrorCheckpointFailed
               userInfo:@{NSLocalizedDescriptionKey : @"fsync failed"}];
    return NO;
  }
  return YES;
}

- (NSString*)escapeJson:(NSString*)s {
  NSMutableString* m = [s mutableCopy];
  [m replaceOccurrencesOfString:@"\\"
                     withString:@"\\\\"
                        options:0
                          range:NSMakeRange(0, m.length)];
  [m replaceOccurrencesOfString:@"\""
                     withString:@"\\\""
                        options:0
                          range:NSMakeRange(0, m.length)];
  [m replaceOccurrencesOfString:@"\n"
                     withString:@"\\n"
                        options:0
                          range:NSMakeRange(0, m.length)];
  [m replaceOccurrencesOfString:@"\r"
                     withString:@"\\r"
                        options:0
                          range:NSMakeRange(0, m.length)];
  [m replaceOccurrencesOfString:@"\t"
                     withString:@"\\t"
                        options:0
                          range:NSMakeRange(0, m.length)];
  return m;
}

+ (NSDateFormatter*)_iso8601Formatter {
  static NSDateFormatter* f;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSXXX";
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
  });
  return f;
}

@end

NS_ASSUME_NONNULL_END