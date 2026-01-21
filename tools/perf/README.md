# iTerm2 Performance Testing Tools

Scripts for stress testing and profiling iTerm2 builds with latency instrumentation.

## Quick Start

```bash
# Basic test (10 tabs, 20 seconds)
./run_multi_tab_stress_test.sh /path/to/iTerm2.app

# Compare behavior across tab counts
./run_multi_tab_stress_test.sh --tabs=1,3,10 /path/to/iTerm2.app

# With title injection (exercises OSC 0 handling)
./run_multi_tab_stress_test.sh --title /path/to/iTerm2.app

# With DTrace metrics (requires sudo)
./run_multi_tab_stress_test.sh --dtrace /path/to/iTerm2.app
```

## Scripts

| Script | Purpose |
|--------|---------|
| `run_multi_tab_stress_test.sh` | Main test harness - opens iTerm2, creates tabs, runs stress load, profiles |
| `stress_load.py` | Generates terminal output to stress rendering |
| `analyze_profile.py` | Analyzes `sample` profiler output for hotspots |
| `iterm_ux_metrics_v2.d` | DTrace script for frame rate and latency metrics |

## Options

```
--tabs=N,M,...    Tab counts to test (runs separate test for each)
--title[=MS]      Inject OSC 0 title changes (default: every 2000ms)
--dtrace          Enable DTrace UX metrics (requires sudo)
--inject          Enable interaction injection (tab switches, keyboard input)
--mode=MODE       Stress mode: normal, buffer, clearcodes, all
--speed=SPEED     Output speed: normal or slow
```

## Output

The test produces:
- **Profile analysis** - CPU hotspots from `sample` profiler
- **Latency metrics** - KeyboardInput, TitleUpdate timings (from instrumented builds)
- **Timer analysis** - GCD/NSTimer efficiency, cadence stability
- **DTrace metrics** - Frame rates, adaptive mode, lock contention (if --dtrace)
- **Summary table** - Cross-run comparison when testing multiple tab counts

## Requirements

- macOS with `sample` profiler
- Python 3
- For --dtrace: sudo access
- Instrumented iTerm2 build (for latency metrics)
