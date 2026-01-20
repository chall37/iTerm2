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

// Counter types for non-latency metrics (simple event counts)
typedef NS_ENUM(NSInteger, MTPerfCounterType) {
    MTPerfCounterVisibleRefresh,      // Refresh calls for visible sessions
    MTPerfCounterBackgroundRefresh,   // Refresh calls for background sessions
    MTPerfCounterCadence60fps,        // fastAdaptiveInterval selected (visible, low throughput)
    MTPerfCounterCadence30fps,        // slowAdaptiveInterval selected (visible, high throughput)
    MTPerfCounterCadence1fps,         // backgroundInterval selected (not visible or idle)
    MTPerfCounterGCDTimerCreate,      // GCD cadence timer created/recreated
    MTPerfCounterNSTimerCreate,       // NSTimer cadence timer created/recreated
    MTPerfCounterGCDTimerFire,        // GCD cadence timer fired
    MTPerfCounterNSTimerFire,         // NSTimer cadence timer fired
    MTPerfCounterCadenceNoChange,     // _cadence == period, no timer recreation needed
    MTPerfCounterCadenceMismatch,     // _cadence != period, timer needs recreation
    MTPerfCounterSlowFR30,            // slowFrameRate == 30 (Metal)
    MTPerfCounterSlowFR15,            // slowFrameRate == 15 (non-Metal)
    MTPerfCounterSlowFROther,         // slowFrameRate is neither 15 nor 30
    MTPerfCounterCount
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

// Counter API for simple event counts (visible/background refresh, cadence mode)
void MTPerfIncrementCounter(MTPerfCounterType type);

#else

// No-op macros when disabled
#define MTPerfStartSession(type, session) ((void)0)
#define MTPerfEndSession(type, session) ((void)0)
#define MTPerfStart(type) ((void)0)
#define MTPerfEnd(type) ((void)0)
#define MTPerfInitialize() ((void)0)
#define MTPerfWriteToFile() ((void)0)
#define MTPerfIncrementCounter(type) ((void)0)

#endif  // ENABLE_MTPERF

#endif  // MTPerfMetrics_h
