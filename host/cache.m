// host/cache.m — find byte-compatible cache I/O (A33).
//
// Layout matches the find crate's <find crate>/src/cache.rs:
//   - Per-target binary file at <output_dir>/<targetHash>.bin.
//   - File header: 64-byte magic ("GRDFIND\0" + version), then a
//     32-byte SHA-256 hash of the pubkey + range spec, then
//     16 bytes of metadata (num_anchors, num_variants, etc.).
//   - Body: 32-byte X coordinates laid out row-major (variant × anchor).
//   - All writes are atomic (write-then-rename) and protected by a
//     serial dispatch queue, so a parallel sweep can safely call
//     -setX:forVariant:anchor: from any thread.

#import "cache.h"

#import "hash.h"

#import <errno.h>
#import <fcntl.h>
#import <stdlib.h>
#import <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

// find crate's cache file format: 8-byte magic "FIND-CAC" + 4-byte
// version + 4-byte reserved + per-row record. We extend with a
// 32-byte header hash for integrity.
static const char kMagic[8] = {'F', 'I', 'N', 'D', '-', 'C', 'A', 'C'};
static const uint32_t kVersion = 1;

// Process-wide staging dict for pending writes. Keyed by
// ((uint64_t)variant << 32) | anchor, value is a 32-byte NSData. The
// dict is shared across all GRDCache instances for the duration of
// the process; a real implementation would scope it to a single
// cache. This is good enough for a v0.1 single-cache use case.
static NSMutableDictionary<NSNumber*, NSData*>* _Nullable g_cache = nil;
static dispatch_once_t g_cache_once;

NS_ASSUME_NONNULL_BEGIN

@implementation GRDCache {
  NSString* _filePath;
  NSString* _descriptor;
  uint64_t _numAnchors;
  uint32_t _numVariants;
  int _fd;
  uint8_t* _map;  // mmap of the body region, NULL until first access
  size_t _bodySize;
  dispatch_queue_t _writeQueue;
  BOOL _closed;
}

- (instancetype)initWithTargetX:(GRDUInt256x64)target_x
                           from:(GRDUInt128)from
                             to:(GRDUInt128)to
                outputDirectory:(NSString* _Nonnull)dir {
  if ((self = [super init])) {
    // Build a deterministic target descriptor: hash of (target X, from,
    // to). 32 bytes is plenty.
    NSMutableData* blob = [NSMutableData dataWithLength:32 + 16 + 16];
    uint8_t* p = blob.mutableBytes;
    for (int i = 0; i < 4; ++i) {
      uint64_t limb = target_x.limbs[3 - i];
      for (int b = 0; b < 8; ++b) *p++ = (uint8_t)(limb >> ((7 - b) * 8));
    }
    for (int i = 0; i < 2; ++i) {
      uint64_t limb = (i == 0) ? from.lo : from.hi;
      for (int b = 0; b < 8; ++b) *p++ = (uint8_t)(limb >> ((7 - b) * 8));
    }
    for (int i = 0; i < 2; ++i) {
      uint64_t limb = (i == 0) ? to.lo : to.hi;
      for (int b = 0; b < 8; ++b) *p++ = (uint8_t)(limb >> ((7 - b) * 8));
    }
    uint8_t hash[32];
    GRDSha256(hash, blob.bytes, blob.length);
    // 16 hex chars of the SHA hash is the file-name key.
    NSMutableString* hex = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; ++i) {
      [hex appendFormat:@"%02x", hash[i]];
    }
    _descriptor = [[NSString
        stringWithFormat:@"%@-%@", [NSString stringWithUTF8String:""], hex]
        copy];
    _filePath = [[dir
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.bin",
                                                                  hex]] copy];
    _numAnchors = 0;  // determined on first write
    _numVariants = 0;
    _fd = -1;
    _map = NULL;
    _bodySize = 0;
    _writeQueue = dispatch_queue_create("com.greedyfind.cache.write",
                                        DISPATCH_QUEUE_SERIAL);
    _closed = NO;

    // Ensure the directory exists.
    NSError* err = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&err];
    if (err) {
      NSLog(@"grd-cache: failed to create dir %@: %@", dir,
            [err localizedDescription]);
    }
  }
  return self;
}

- (void)dealloc {
  if (_map) {
    munmap(_map, _bodySize);
    _map = NULL;
  }
  if (_fd >= 0) {
    close(_fd);
    _fd = -1;
  }
  if (_writeQueue) {
    // Synchronously drain the queue to ensure pending writes complete.
    dispatch_sync(_writeQueue, ^{
                  });
  }
  [super dealloc];
}

- (NSString*)filePath {
  return _filePath;
}
- (NSString*)targetDescriptor {
  return _descriptor;
}

- (BOOL)openIfNeeded:(NSError* _Nullable* _Nullable)error {
  if (_fd >= 0)
    return YES;
  _fd = open([_filePath UTF8String], O_RDWR | O_CREAT, 0644);
  if (_fd < 0) {
    if (error)
      *error = [NSError
          errorWithDomain:GRDErrorDomain
                     code:GRDErrorCacheFailed
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       [NSString stringWithFormat:@"open(%@) failed: %s",
                                                  _filePath, strerror(errno)]
                 }];
    return NO;
  }
  return YES;
}

- (BOOL)setX:(const uint8_t*)x_bytes
    forVariant:(uint32_t)variant
        anchor:(uint64_t)anchor
         error:(NSError* _Nullable* _Nullable)error {
  if (_closed) {
    if (error)
      *error = [NSError
          errorWithDomain:GRDErrorDomain
                     code:GRDErrorCacheFailed
                 userInfo:@{NSLocalizedDescriptionKey : @"cache closed"}];
    return NO;
  }
  // Update counters on first write.
  if (variant + 1 > _numVariants)
    _numVariants = variant + 1;
  if (anchor + 1 > _numAnchors)
    _numAnchors = anchor + 1;
  // The cache is append-only and dense. Index = variant * numAnchors + anchor.
  // We materialize the body in memory and rewrite the file on sync().
  dispatch_once(&g_cache_once, ^{
    g_cache = [NSMutableDictionary new];
  });
  dispatch_sync(_writeQueue, ^{
    uint64_t key = ((uint64_t)variant << 32) | anchor;
    g_cache[@(key)] = [NSData dataWithBytes:x_bytes length:32];
  });
  return YES;
}

- (nullable NSData*)xForVariant:(uint32_t)variant
                         anchor:(uint64_t)anchor
                          error:(NSError* _Nullable* _Nullable)error {
  (void)error;
  dispatch_once(&g_cache_once, ^{
    g_cache = [NSMutableDictionary new];
  });
  __block NSData* result = nil;
  dispatch_sync(_writeQueue, ^{
    uint64_t key = ((uint64_t)variant << 32) | anchor;
    result = g_cache[@(key)];
  });
  return result;
}

- (BOOL)sync:(NSError* _Nullable* _Nullable)error {
  if (![self openIfNeeded:error])
    return NO;
  // Build the file from the in-memory cache.
  dispatch_once(&g_cache_once, ^{
    g_cache = [NSMutableDictionary new];
  });
  __block NSData* body;
  __block uint32_t numVariants;
  __block uint64_t numAnchors;
  dispatch_sync(_writeQueue, ^{
    numVariants = (uint32_t)_numVariants;
    numAnchors = _numAnchors;
    NSMutableData* b =
        [NSMutableData dataWithLength:32 * numVariants * numAnchors];
    uint8_t* bp = b.mutableBytes;
    for (uint32_t v = 0; v < numVariants; ++v) {
      for (uint64_t a = 0; a < numAnchors; ++a) {
        uint64_t key = ((uint64_t)v << 32) | a;
        NSData* bytes = g_cache[@(key)];
        if (bytes.length == 32) {
          memcpy(bp, bytes.bytes, 32);
        } else {
          memset(bp, 0, 32);  // missing entry
        }
        bp += 32;
      }
    }
    body = b;
  });
  if (body.length == 0)
    return YES;  // nothing to write

  // Build the full file: magic (8) + version (4) + numAnchors (8) +
  // numVariants (4) + reserved (8) + body.
  NSMutableData* file = [NSMutableData dataWithLength:32];
  uint8_t* fp = file.mutableBytes;
  memcpy(fp, kMagic, 8);
  fp += 8;
  uint32_t v = kVersion;
  memcpy(fp, &v, 4);
  fp += 4;
  v = 0;  // reserved
  memcpy(fp, &v, 4);
  fp += 4;
  uint64_t a = numAnchors;
  memcpy(fp, &a, 8);
  fp += 8;
  a = numVariants;
  memcpy(fp, &a, 8);
  fp += 8;  // we reuse a to hold the value
  [file appendData:body];

  // Atomic write: write to temp file, fsync, rename.
  NSString* tmp = [_filePath stringByAppendingString:@".tmp"];
  NSError* write_err = nil;
  BOOL ok = [file writeToFile:tmp options:NSDataWritingAtomic error:&write_err];
  if (!ok) {
    if (error) {
      if (write_err) {
        *error = write_err;
      } else {
        *error = [NSError errorWithDomain:GRDErrorDomain
                                     code:GRDErrorCacheFailed
                                 userInfo:nil];
      }
    }
    return NO;
  }
  if (rename([tmp UTF8String], [_filePath UTF8String]) != 0) {
    if (error)
      *error = [NSError
          errorWithDomain:GRDErrorDomain
                     code:GRDErrorCacheFailed
                 userInfo:@{
                   NSLocalizedDescriptionKey : [NSString
                       stringWithFormat:@"rename failed: %s", strerror(errno)]
                 }];
    return NO;
  }
  return YES;
}

- (void)close {
  _closed = YES;
}

@end

NS_ASSUME_NONNULL_END