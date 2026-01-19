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
    MTPerfMetricTitleUpdate,         // setWindowTitle -> title displayed
    MTPerfMetricDoubleBufferExpire,  // reset -> temporaryDoubleBufferedGridDidExpire
    MTPerfMetricPostJoinedRefresh,   // performBlockWithJoinedThreads returns -> updateDisplayBecause completes
    MTPerfMetricCount                // = 8
};

// Lock-free API (uses raw mach_absolute_time, ~40ns overhead)
void MTPerfStart(MTPerfMetricType type);
void MTPerfEnd(MTPerfMetricType type);

// Called once at startup to generate timestamp and initialize
void MTPerfInitialize(void);

// Called at app termination to write metrics file
void MTPerfWriteToFile(void);

#else

// No-op macros when disabled
#define MTPerfStart(type) ((void)0)
#define MTPerfEnd(type) ((void)0)
#define MTPerfInitialize() ((void)0)
#define MTPerfWriteToFile() ((void)0)

#endif  // ENABLE_MTPERF

#endif  // MTPerfMetrics_h
