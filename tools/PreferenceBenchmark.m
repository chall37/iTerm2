//
//  PreferenceBenchmark.m
//  Synthetic benchmark demonstrating NSUserDefaults vs cached preference lookup overhead
//
//  This demonstrates the performance principle behind the bidi preference caching fix.
//  Run: clang -fobjc-arc -framework Foundation PreferenceBenchmark.m -o PreferenceBenchmark && ./PreferenceBenchmark
//

#import <Foundation/Foundation.h>

// Simulate the FAST_BOOL_ACCESSOR pattern used in iTermPreferences
static BOOL gCachedBidiEnabled = NO;
static dispatch_once_t gBidiOnceToken;

static BOOL getCachedBidiEnabled(void) {
    dispatch_once(&gBidiOnceToken, ^{
        gCachedBidiEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"BidiEnabled"];
    });
    return gCachedBidiEnabled;
}

static BOOL getUncachedBidiEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"BidiEnabled"];
}

// Simulate work that StringToScreenChars does per character
static void processCharacter(unichar c, BOOL bidiEnabled) {
    // Simulate RTL character set check (simplified)
    if (bidiEnabled) {
        // Hebrew: 0x0590-0x05FF, Arabic: 0x0600-0x06FF
        if ((c >= 0x0590 && c <= 0x05FF) || (c >= 0x0600 && c <= 0x06FF)) {
            // Would mark RTL found
        }
    }
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        printf("=== Preference Lookup Benchmark ===\n\n");
        printf("This demonstrates the overhead of NSUserDefaults in a hot loop\n");
        printf("vs using a cached value (dispatch_once pattern).\n\n");

        // Set up test data
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"BidiEnabled"];

        // Test strings simulating terminal output
        NSString *testString = @"Hello שלום World 日本語 العربية mixed content test string for benchmarking";
        NSUInteger stringLen = testString.length;
        unichar *chars = malloc(stringLen * sizeof(unichar));
        [testString getCharacters:chars range:NSMakeRange(0, stringLen)];

        const int ITERATIONS = 1000000;
        const int STRING_ITERATIONS = 100000;

        // Warm up
        for (int i = 0; i < 1000; i++) {
            (void)getCachedBidiEnabled();
            (void)getUncachedBidiEnabled();
        }

        printf("--- Raw Preference Lookup (%d iterations) ---\n", ITERATIONS);

        // Benchmark cached lookup
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        for (int i = 0; i < ITERATIONS; i++) {
            (void)getCachedBidiEnabled();
        }
        CFAbsoluteTime cachedTime = CFAbsoluteTimeGetCurrent() - start;

        // Benchmark uncached lookup
        start = CFAbsoluteTimeGetCurrent();
        for (int i = 0; i < ITERATIONS; i++) {
            (void)getUncachedBidiEnabled();
        }
        CFAbsoluteTime uncachedTime = CFAbsoluteTimeGetCurrent() - start;

        printf("Cached (dispatch_once):   %.3f ms  (%.0f iters/sec)\n",
               cachedTime * 1000, ITERATIONS / cachedTime);
        printf("Uncached (NSUserDefaults): %.3f ms  (%.0f iters/sec)\n",
               uncachedTime * 1000, ITERATIONS / uncachedTime);
        printf("Speedup: %.1fx faster\n\n", uncachedTime / cachedTime);

        printf("--- Simulated String Processing (%d strings × %lu chars) ---\n",
               STRING_ITERATIONS, stringLen);

        // Reset the once token for fair comparison
        gBidiOnceToken = 0;

        // Benchmark with cached preference (like our fix)
        start = CFAbsoluteTimeGetCurrent();
        for (int iter = 0; iter < STRING_ITERATIONS; iter++) {
            BOOL bidi = getCachedBidiEnabled();
            for (NSUInteger i = 0; i < stringLen; i++) {
                processCharacter(chars[i], bidi);
            }
        }
        CFAbsoluteTime cachedStringTime = CFAbsoluteTimeGetCurrent() - start;

        // Benchmark with uncached preference (like the old code)
        start = CFAbsoluteTimeGetCurrent();
        for (int iter = 0; iter < STRING_ITERATIONS; iter++) {
            BOOL bidi = getUncachedBidiEnabled();
            for (NSUInteger i = 0; i < stringLen; i++) {
                processCharacter(chars[i], bidi);
            }
        }
        CFAbsoluteTime uncachedStringTime = CFAbsoluteTimeGetCurrent() - start;

        printf("With cached pref:   %.3f ms  (%.0f strings/sec)\n",
               cachedStringTime * 1000, STRING_ITERATIONS / cachedStringTime);
        printf("With uncached pref: %.3f ms  (%.0f strings/sec)\n",
               uncachedStringTime * 1000, STRING_ITERATIONS / uncachedStringTime);
        printf("Speedup: %.1fx faster\n\n", uncachedStringTime / cachedStringTime);

        // Per-call overhead
        double uncachedOverheadNs = (uncachedTime / ITERATIONS) * 1e9;
        double cachedOverheadNs = (cachedTime / ITERATIONS) * 1e9;
        printf("--- Per-Call Overhead ---\n");
        printf("NSUserDefaults boolForKey: %.1f ns/call\n", uncachedOverheadNs);
        printf("Cached dispatch_once:      %.1f ns/call\n", cachedOverheadNs);
        printf("Savings per call:          %.1f ns\n\n", uncachedOverheadNs - cachedOverheadNs);

        // Impact estimate
        double callsPerSecond = 10000; // Rough estimate during heavy output
        double savedMsPerSecond = (uncachedOverheadNs - cachedOverheadNs) * callsPerSecond / 1e6;
        printf("--- Estimated Impact ---\n");
        printf("At ~%.0f StringToScreenChars calls/sec during heavy output:\n", callsPerSecond);
        printf("Saved CPU time: ~%.2f ms/sec\n", savedMsPerSecond);

        free(chars);

        // Multi-threaded contention test
        const int NUM_THREADS = 14;
        const int ITERS_PER_THREAD = ITERATIONS / NUM_THREADS;
        printf("--- Multi-threaded Contention Test (%d threads, %d iterations each) ---\n",
               NUM_THREADS, ITERS_PER_THREAD);

        CFAbsoluteTime *threadCachedTimes = calloc(NUM_THREADS, sizeof(CFAbsoluteTime));
        CFAbsoluteTime *threadUncachedTimes = calloc(NUM_THREADS, sizeof(CFAbsoluteTime));

        dispatch_group_t group = dispatch_group_create();
        dispatch_queue_t concurrentQueue = dispatch_queue_create("benchmark", DISPATCH_QUEUE_CONCURRENT);

        // Test cached access from all threads
        gBidiOnceToken = 0; // Reset
        for (int t = 0; t < NUM_THREADS; t++) {
            const int threadIdx = t;
            dispatch_group_async(group, concurrentQueue, ^{
                CFAbsoluteTime s = CFAbsoluteTimeGetCurrent();
                for (int i = 0; i < ITERS_PER_THREAD; i++) {
                    (void)getCachedBidiEnabled();
                }
                threadCachedTimes[threadIdx] = CFAbsoluteTimeGetCurrent() - s;
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

        double maxCachedTime = 0;
        for (int t = 0; t < NUM_THREADS; t++) {
            if (threadCachedTimes[t] > maxCachedTime) maxCachedTime = threadCachedTimes[t];
        }

        // Test uncached access from all threads (causes lock contention)
        for (int t = 0; t < NUM_THREADS; t++) {
            const int threadIdx = t;
            dispatch_group_async(group, concurrentQueue, ^{
                CFAbsoluteTime s = CFAbsoluteTimeGetCurrent();
                for (int i = 0; i < ITERS_PER_THREAD; i++) {
                    (void)getUncachedBidiEnabled();
                }
                threadUncachedTimes[threadIdx] = CFAbsoluteTimeGetCurrent() - s;
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

        double maxUncachedTime = 0;
        for (int t = 0; t < NUM_THREADS; t++) {
            if (threadUncachedTimes[t] > maxUncachedTime) maxUncachedTime = threadUncachedTimes[t];
        }

        printf("Cached (parallel):    %.3f ms  (%.0f iters/sec total)\n",
               maxCachedTime * 1000, ITERATIONS / maxCachedTime);
        printf("Uncached (parallel):  %.3f ms  (%.0f iters/sec total)\n",
               maxUncachedTime * 1000, ITERATIONS / maxUncachedTime);
        printf("Contention speedup:   %.1fx faster with caching\n", maxUncachedTime / maxCachedTime);

        free(threadCachedTimes);
        free(threadUncachedTimes);

        printf("\n=== Benchmark Complete ===\n");
    }
    return 0;
}
