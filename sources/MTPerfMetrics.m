//
//  MTPerfMetrics.m
//  iTerm2
//
//  Lock-free latency instrumentation for multi-tab stress testing.
//  Uses raw mach_absolute_time (~40ns overhead) instead of @synchronized.
//

#import "MTPerfMetrics.h"

#if ENABLE_MTPERF

#import <mach/mach_time.h>
#import <math.h>

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

static MTPerfStat gStats[MTPerfMetricCount];
static char gTimestamp[20];  // "20260116_120517"
static mach_timebase_info_data_t gTimebaseInfo;
static BOOL gInitialized = NO;

void MTPerfInitialize(void) {
    if (gInitialized) return;

    mach_timebase_info(&gTimebaseInfo);

    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    strftime(gTimestamp, sizeof(gTimestamp), "%Y%m%d_%H%M%S", tm);

    memset(gStats, 0, sizeof(gStats));
    for (int i = 0; i < MTPerfMetricCount; i++) {
        gStats[i].min = UINT64_MAX;
    }

    gInitialized = YES;
}

void MTPerfStart(MTPerfMetricType type) {
    if (!gInitialized || type < 0 || type >= MTPerfMetricCount) return;
    gStats[type].startTime = mach_absolute_time();
}

void MTPerfEnd(MTPerfMetricType type) {
    uint64_t end = mach_absolute_time();

    if (!gInitialized || type < 0 || type >= MTPerfMetricCount) return;

    uint64_t start = gStats[type].startTime;
    if (start == 0) return;  // No matching start

    uint64_t elapsed = end - start;
    MTPerfStat *s = &gStats[type];

    s->count++;
    s->sum += elapsed;
    s->sumSquares += (double)elapsed * elapsed;
    if (elapsed < s->min) s->min = elapsed;
    if (elapsed > s->max) s->max = elapsed;
    s->startTime = 0;  // Reset for next measurement
}

void MTPerfWriteToFile(void) {
    if (!gInitialized) return;

    char path[256];
    snprintf(path, sizeof(path), "/tmp/mtperf_latency_%s.txt", gTimestamp);

    FILE *f = fopen(path, "w");
    if (!f) return;

    // Convert timebase to nanoseconds
    double toNs = (double)gTimebaseInfo.numer / gTimebaseInfo.denom;

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

    fprintf(f, "# MTPerfMetrics Latency - %s\n", gTimestamp);
    fprintf(f, "# metric,count,mean_ns,min_ns,max_ns,stddev_ns\n");

    for (int i = 0; i < MTPerfMetricCount; i++) {
        MTPerfStat *s = &gStats[i];
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

#endif  // ENABLE_MTPERF
