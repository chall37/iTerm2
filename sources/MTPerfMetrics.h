//
//  MTPerfMetrics.h
//  iTerm2
//
//  Header-only latency instrumentation for multi-tab stress testing.
//  Measures user-perceived latency across interaction types.
//  Uses raw mach_absolute_time (~40ns overhead) instead of @synchronized.
//

#ifndef MTPerfMetrics_h
#define MTPerfMetrics_h

#ifndef ENABLE_MTPERF
#define ENABLE_MTPERF 0  // Build flag - set via xcconfig to enable instrumentation
#endif

#if ENABLE_MTPERF

#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <math.h>

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

// Per-metric statistics structure
// No locks needed - single-threaded aggregation at quit is acceptable
// for diagnostics. Worst case: a few samples lost due to races.
typedef struct {
    uint64_t startTime;     // Current start timestamp (0 if not measuring)
    uint64_t count;         // Number of completed measurements
    double sum;             // Sum of elapsed times (for mean)
    double sumSquares;      // Sum of squared times (for variance)
    uint64_t min;           // Minimum elapsed time
    uint64_t max;           // Maximum elapsed time
} MTPerfStat;

// Internal storage access - ensures single definition across translation units
static inline MTPerfStat *_MTPerfStats(void) {
    static MTPerfStat stats[MTPerfMetricCount];
    return stats;
}

static inline char *_MTPerfTimestamp(void) {
    static char timestamp[20];
    return timestamp;
}

static inline mach_timebase_info_data_t *_MTPerfTimebase(void) {
    static mach_timebase_info_data_t info;
    return &info;
}

static inline BOOL *_MTPerfInitialized(void) {
    static BOOL initialized = NO;
    return &initialized;
}

static inline void MTPerfInitialize(void) {
    if (*_MTPerfInitialized()) return;

    mach_timebase_info(_MTPerfTimebase());

    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    strftime(_MTPerfTimestamp(), 20, "%Y%m%d_%H%M%S", tm);

    MTPerfStat *stats = _MTPerfStats();
    memset(stats, 0, sizeof(MTPerfStat) * MTPerfMetricCount);
    for (int i = 0; i < MTPerfMetricCount; i++) {
        stats[i].min = UINT64_MAX;
    }

    *_MTPerfInitialized() = YES;
}

static inline void MTPerfStart(MTPerfMetricType type) {
    if (!*_MTPerfInitialized() || type < 0 || type >= MTPerfMetricCount) return;
    _MTPerfStats()[type].startTime = mach_absolute_time();
}

static inline void MTPerfEnd(MTPerfMetricType type) {
    uint64_t end = mach_absolute_time();

    if (!*_MTPerfInitialized() || type < 0 || type >= MTPerfMetricCount) return;

    MTPerfStat *stats = _MTPerfStats();
    uint64_t start = stats[type].startTime;
    if (start == 0) return;  // No matching start

    uint64_t elapsed = end - start;
    MTPerfStat *s = &stats[type];

    s->count++;
    s->sum += elapsed;
    s->sumSquares += (double)elapsed * elapsed;
    if (elapsed < s->min) s->min = elapsed;
    if (elapsed > s->max) s->max = elapsed;
    s->startTime = 0;  // Reset for next measurement
}

static inline void MTPerfWriteToFile(void) {
    if (!*_MTPerfInitialized()) return;

    char path[256];
    snprintf(path, sizeof(path), "/tmp/mtperf_latency_%s.txt", _MTPerfTimestamp());

    FILE *f = fopen(path, "w");
    if (!f) return;

    // Convert timebase to nanoseconds
    mach_timebase_info_data_t *tb = _MTPerfTimebase();
    double toNs = (double)tb->numer / tb->denom;

    static const char *names[] = {
        "KeyboardInput",
        "Output",
        "MouseClick",
        "TabSwitch",
        "WindowFocus",
        "TitleUpdate",
        "DoubleBufferExpire",
        "PostJoinedRefresh"
    };

    fprintf(f, "# MTPerfMetrics Latency - %s\n", _MTPerfTimestamp());
    fprintf(f, "# metric,count,mean_ns,min_ns,max_ns,stddev_ns\n");

    MTPerfStat *stats = _MTPerfStats();
    for (int i = 0; i < MTPerfMetricCount; i++) {
        MTPerfStat *s = &stats[i];
        if (s->count == 0) {
            fprintf(f, "%s,0,0,0,0,0\n", names[i]);
            continue;
        }

        double meanRaw = s->sum / s->count;
        double mean = meanRaw * toNs;
        double varianceRaw = (s->sumSquares / s->count) - (meanRaw * meanRaw);
        double variance = varianceRaw * toNs * toNs;
        double stddev = sqrt(variance > 0 ? variance : 0);

        fprintf(f, "%s,%llu,%.0f,%.0f,%.0f,%.0f\n",
                names[i],
                s->count,
                mean,
                s->min * toNs,
                s->max * toNs,
                stddev);
    }

    fclose(f);
}

#else

// No-op macros when disabled
#define MTPerfStart(type) ((void)0)
#define MTPerfEnd(type) ((void)0)
#define MTPerfInitialize() ((void)0)
#define MTPerfWriteToFile() ((void)0)

#endif  // ENABLE_MTPERF

#endif  // MTPerfMetrics_h
