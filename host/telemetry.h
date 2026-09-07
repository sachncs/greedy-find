// host/telemetry.h — NDJSON telemetry + rolling text log (A35).
//
// Records sweep events to a single NDJSON file (one event per line)
// for ingestion by dashboards. The same file is also human-readable
// as a rolling text log. Events are emitted through a serial dispatch
// queue, so callers can fire-and-forget from any thread.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Event levels. The text log level is the minimum level to write;
 * NDJSON always records every event.
 */
typedef NS_ENUM(NSInteger, GRDLogLevel) {
  GRDLogLevelDebug = 0,
  GRDLogLevelInfo = 1,
  GRDLogLevelWarn = 2,
  GRDLogLevelError = 3,
};

@interface GRDTelemetry : NSObject

- (instancetype)initWithOutputDirectory:(NSString* _Nonnull)dir
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Emit an event. Safe to call from any thread. */
- (void)emitEvent:(NSString* _Nonnull)name
            level:(GRDLogLevel)level
           fields:(nullable NSDictionary<NSString*, id>*)fields;

/** Force a flush of the underlying log file. */
- (BOOL)flush:(NSError* _Nullable* _Nullable)error;

@property(nonatomic, readonly) NSString* _Nonnull outputDirectory;
@property(nonatomic, readonly) NSString* _Nonnull ndjsonPath;
@property(nonatomic, readonly) NSString* _Nonnull textPath;
@property(nonatomic, assign) GRDLogLevel textLevel;

@end

NS_ASSUME_NONNULL_END