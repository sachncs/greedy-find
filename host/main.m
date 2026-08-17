// host/main.m — CLI entry point for greedyfind.
//
// The actual session logic lives in host/sweep.m and is exposed via
// GRDRunSession. This file is responsible only for argument parsing and
// dispatch into the session runner.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Runs a complete greedyfind session from the supplied argv. Exposed by
 * host/sweep.m. Returns the process exit code (0 = success, non-zero =
 * failure with a message written to stderr).
 */
int GRDRunSession(int argc, const char *_Nonnull *_Nonnull argv);

NS_ASSUME_NONNULL_END

/**
 * main — argv[0] is the program name; remaining args are greedyfind flags.
 */
int main(int argc, const char *_Nonnull argv[]) {
  @autoreleasepool {
    return GRDRunSession(argc, argv);
  }
}