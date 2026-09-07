// host/checkpoint.m — atomic write-then-rename checkpoint (A34).
//
// Format: a tiny JSON file with two fields
//   { "next_j_lo": <hex>, "next_j_hi": <hex>, "integrity": <hex> }
// The integrity field is a SHA-256 of the JSON body (excluding the
// integrity field) for tamper detection. Writes go to a temp file
// and are atomically renamed into place so a crash mid-write can't
// leave a half-written checkpoint.

#import "checkpoint.h"

#import "hash.h"

#import <errno.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

NS_ASSUME_NONNULL_BEGIN

@implementation GRDCheckpoint {
  GRDUInt128 _next_j;
  NSString* _targetDescriptor;
}

- (instancetype)initWithNextJ:(GRDUInt128)j targetDescriptor:(NSString*)target {
  if ((self = [super init])) {
    _next_j = j;
    _targetDescriptor = [target copy];
  }
  return self;
}

- (NSString*)description {
  char buf[40];
  GRDU128FormatDecimal(buf, sizeof(buf), self.next_j);
  return [NSString stringWithFormat:@"GRDCheckpoint(next_j=%s, target=%@)", buf,
                                    self.targetDescriptor];
}

@end

@implementation GRDCheckpointStore

- (instancetype)initWithOutputDirectory:(NSString*)dir {
  if ((self = [super init])) {
    _outputDirectory = [dir copy];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
  }
  return self;
}

- (BOOL)saveCheckpoint:(GRDCheckpoint*)cp
                 error:(NSError* _Nullable* _Nullable)error {
  char jlo[20], jhi[20];
  snprintf(jlo, sizeof jlo, "%llx", (unsigned long long)cp.next_j.lo);
  snprintf(jhi, sizeof jhi, "%llx", (unsigned long long)cp.next_j.hi);
  // body is the field list without the surrounding braces. The
  // integrity hash covers exactly these bytes so the loader can
  // re-derive the same prefix and verify.
  NSString* body = [NSString
      stringWithFormat:@"\"next_j_lo\":\"%s\",\"next_j_hi\":\"%s\"", jlo, jhi];
  NSData* body_data = [body dataUsingEncoding:NSUTF8StringEncoding];

  // Integrity: SHA-256 of body bytes.
  uint8_t hash[32];
  GRDSha256(hash, body_data.bytes, body_data.length);
  NSMutableString* hex = [NSMutableString stringWithCapacity:64];
  for (int i = 0; i < 32; ++i) [hex appendFormat:@"%02x", hash[i]];

  NSString* full =
      [NSString stringWithFormat:@"{%@,\"integrity\":\"%@\"}", body, hex];
  NSData* full_data = [full dataUsingEncoding:NSUTF8StringEncoding];

  NSString* path = [NSString
      stringWithFormat:@"%@/%@.ckpt", _outputDirectory, cp.targetDescriptor];
  NSString* tmp = [path stringByAppendingPathExtension:@"tmp"];
  NSError* err = nil;
  if (![full_data writeToFile:tmp options:NSDataWritingAtomic error:&err]) {
    if (error)
      *error = err;
    return NO;
  }
  if (rename([tmp UTF8String], [path UTF8String]) != 0) {
    if (error)
      *error = [NSError
          errorWithDomain:GRDErrorDomain
                     code:GRDErrorCheckpointFailed
                 userInfo:@{
                   NSLocalizedDescriptionKey : [NSString
                       stringWithFormat:@"rename failed: %s", strerror(errno)]
                 }];
    return NO;
  }
  return YES;
}

- (nullable GRDCheckpoint*)
    loadCheckpointForDescriptor:(NSString*)desc
                          error:(NSError* _Nullable* _Nullable)error {
  NSString* path =
      [NSString stringWithFormat:@"%@/%@.ckpt", _outputDirectory, desc];
  // "clean start" is signalled by a missing file: no checkpoint, no
  // error. Suppress any NSError the file-read API would otherwise set.
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    if (error)
      *error = nil;
    return nil;
  }
  NSData* data = [NSData dataWithContentsOfFile:path options:0 error:error];
  if (!data)
    return nil;
  NSString* content = [[NSString alloc] initWithData:data
                                            encoding:NSUTF8StringEncoding];
  if (!content) {
    if (error)
      *error = [NSError
          errorWithDomain:GRDErrorDomain
                     code:GRDErrorCheckpointFailed
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Checkpoint is not UTF-8"
                 }];
    return nil;
  }
  // Parse: look for "next_j_lo" and "next_j_hi" and "integrity" fields.
  NSString* jlo_str = [self extractField:@"next_j_lo" from:content];
  NSString* jhi_str = [self extractField:@"next_j_hi" from:content];
  NSString* integ = [self extractField:@"integrity" from:content];
  if (!jlo_str || !jhi_str || !integ) {
    if (error)
      *error = [NSError
          errorWithDomain:GRDErrorDomain
                     code:GRDErrorCheckpointFailed
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Checkpoint missing fields"
                 }];
    return nil;
  }
  // Verify integrity. The hashed body is the field list (no surrounding
  // braces), so strip the leading '{' from the loaded prefix.
  NSUInteger integrity_loc = [content rangeOfString:@",\"integrity"].location;
  if (integrity_loc == NSNotFound || integrity_loc < 1) {
    if (error)
      *error = [NSError
          errorWithDomain:GRDErrorDomain
                     code:GRDErrorCheckpointFailed
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Checkpoint missing integrity"
                 }];
    return nil;
  }
  NSString* body =
      [content substringWithRange:NSMakeRange(1, integrity_loc - 1)];
  NSData* body_data = [body dataUsingEncoding:NSUTF8StringEncoding];
  uint8_t hash[32];
  GRDSha256(hash, body_data.bytes, body_data.length);
  NSMutableString* expected = [NSMutableString stringWithCapacity:64];
  for (int i = 0; i < 32; ++i) [expected appendFormat:@"%02x", hash[i]];
  if (![integ isEqualToString:expected]) {
    if (error)
      *error = [NSError errorWithDomain:GRDErrorDomain
                                   code:GRDErrorCheckpointFailed
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Checkpoint integrity check failed"
                               }];
    return nil;
  }
  GRDUInt128 j = (GRDUInt128){.lo = strtoull(jlo_str.UTF8String, NULL, 16),
                              .hi = strtoull(jhi_str.UTF8String, NULL, 16)};
  return [[GRDCheckpoint alloc] initWithNextJ:j targetDescriptor:desc];
}

- (NSString*)extractField:(NSString*)name from:(NSString*)json {
  NSString* needle = [NSString stringWithFormat:@"\"%@\":\"", name];
  NSRange r = [json rangeOfString:needle];
  if (r.location == NSNotFound)
    return nil;
  NSUInteger start = r.location + needle.length;
  NSRange end = [json rangeOfString:@"\""
                            options:0
                              range:NSMakeRange(start, json.length - start)];
  if (end.location == NSNotFound)
    return nil;
  return [json substringWithRange:NSMakeRange(start, end.location - start)];
}

@end

NS_ASSUME_NONNULL_END