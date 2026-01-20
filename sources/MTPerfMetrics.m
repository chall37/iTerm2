//
//  MTPerfMetrics.m
//  iTerm2
//
//  Low-overhead latency instrumentation for multi-tab stress testing.
//  Uses atomics for start timestamps and a small lock for aggregate updates.
//

#import "MTPerfMetrics.h"

#if ENABLE_MTPERF

#import <mach/mach_time.h>
#import <math.h>
#import <os/lock.h>
#import <stdatomic.h>

// Per-metric statistics structure (aggregated across all sessions)
typedef struct {
    uint64_t startTime;     // Global startTime for app-level metrics (WindowFocus)
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
static os_unfair_lock gStatsLock = OS_UNFAIR_LOCK_INIT;

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
    __atomic_store_n(&gStats[type].startTime, mach_absolute_time(), __ATOMIC_RELEASE);
}

void MTPerfEnd(MTPerfMetricType type) {
    if (!gInitialized || type < 0 || type >= MTPerfMetricCount) return;

    // Atomic exchange: read start time and clear it in one operation
    uint64_t start = __atomic_exchange_n(&gStats[type].startTime, 0, __ATOMIC_ACQ_REL);
    if (start == 0) return;  // No matching start - avoid mach_absolute_time()

    uint64_t end = mach_absolute_time();
    uint64_t elapsed = end - start;

    // Lock for aggregating into global stats (multi-field update)
    os_unfair_lock_lock(&gStatsLock);
    MTPerfStat *s = &gStats[type];
    s->count++;
    s->sum += elapsed;
    s->sumSquares += (double)elapsed * elapsed;
    if (elapsed < s->min) s->min = elapsed;
    if (elapsed > s->max) s->max = elapsed;
    os_unfair_lock_unlock(&gStatsLock);
}

// Session-aware: stores startTime on the session object itself
void MTPerfStartSession(MTPerfMetricType type, void *session) {
    if (!gInitialized || !session || type < 0 || type >= MTPerfMetricCount) return;
    id<MTPerfSession> s = (__bridge id<MTPerfSession>)session;
    __atomic_store_n(&[s mtperfStartTimes][type], mach_absolute_time(), __ATOMIC_RELEASE);
}

void MTPerfEndSession(MTPerfMetricType type, void *session) {
    if (!gInitialized || !session || type < 0 || type >= MTPerfMetricCount) return;

    id<MTPerfSession> s = (__bridge id<MTPerfSession>)session;
    uint64_t *times = [s mtperfStartTimes];

    // Atomic exchange: read start time and clear it in one operation
    uint64_t start = __atomic_exchange_n(&times[type], 0, __ATOMIC_ACQ_REL);
    if (start == 0) return;  // No matching start - avoid mach_absolute_time()

    uint64_t end = mach_absolute_time();
    uint64_t elapsed = end - start;

    // Lock only for aggregating into global stats
    os_unfair_lock_lock(&gStatsLock);
    MTPerfStat *stat = &gStats[type];
    stat->count++;
    stat->sum += elapsed;
    stat->sumSquares += (double)elapsed * elapsed;
    if (elapsed < stat->min) stat->min = elapsed;
    if (elapsed > stat->max) stat->max = elapsed;
    os_unfair_lock_unlock(&gStatsLock);
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
        "TabTitleUpdate",
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
