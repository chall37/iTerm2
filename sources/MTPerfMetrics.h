//
//  MTPerfMetrics.h
//  iTerm2
//
//  Latency instrumentation for multi-tab stress testing.
//  Measures user-perceived latency across interaction types.
//

#ifndef MTPerfMetrics_h
#define MTPerfMetrics_h

#ifndef ENABLE_MTPERF
#define ENABLE_MTPERF 0  // Build flag - set via xcconfig to enable instrumentation
#endif

#if ENABLE_MTPERF

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, MTPerfMetricType) {
    MTPerfMetricKeyboardInput,       // insertText -> writeTask
    MTPerfMetricOutput,              // processRead -> tokenExecutorDidExecute
    MTPerfMetricMouseClick,          // mouseDown -> setNeedsDisplay/refresh
    MTPerfMetricTabSwitch,           // didSelectTabViewItem -> first refresh
    MTPerfMetricWindowFocus,         // windowDidBecomeKey -> first refresh
    MTPerfMetricTitleUpdate,         // setWindowTitle -> window title displayed
    MTPerfMetricTabTitleUpdate,      // setIconName -> tab label displayed
    MTPerfMetricDoubleBufferExpire,  // reset -> temporaryDoubleBufferedGridDidExpire
    MTPerfMetricPostJoinedRefresh,   // performBlockWithJoinedThreads returns -> updateDisplayBecause completes
    MTPerfMetricCount                // = 9
};

// Protocol for objects that store per-session start times
// PTYSession conforms to this when ENABLE_MTPERF is set
@protocol MTPerfSession <NSObject>
- (uint64_t *)mtperfStartTimes;
@end

// Session-aware API: stores startTime on the session object itself
// Pass the PTYSession pointer (or nil for global fallback)
void MTPerfStartSession(MTPerfMetricType type, void *session);
void MTPerfEndSession(MTPerfMetricType type, void *session);

// Global API for app-level metrics (WindowFocus) - uses shared startTime
void MTPerfStart(MTPerfMetricType type);
void MTPerfEnd(MTPerfMetricType type);

// Called once at startup to generate timestamp and initialize
void MTPerfInitialize(void);

// Called at app termination to write metrics file
void MTPerfWriteToFile(void);

#else

// No-op macros when disabled
#define MTPerfStartSession(type, session) ((void)0)
#define MTPerfEndSession(type, session) ((void)0)
#define MTPerfStart(type) ((void)0)
#define MTPerfEnd(type) ((void)0)
#define MTPerfInitialize() ((void)0)
#define MTPerfWriteToFile() ((void)0)

#endif  // ENABLE_MTPERF

#endif  // MTPerfMetrics_h
