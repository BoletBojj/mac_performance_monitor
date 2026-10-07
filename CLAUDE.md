# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

A macOS SwiftUI app ("Performance App") that displays live CPU load (overall, per-core, and split by Performance/Efficiency core type) and static hardware/GPU specs. Built incrementally with Claude Code as a learning project (see README.md).

## Commands

The project is a plain Xcode project at `Performance App/Performance App.xcodeproj` (no workspace, no SPM dependencies). Scheme name: `Performance App`.

Build, run, and test normally via Xcode (⌘B / ⌘R / ⌘U) with the "My Mac" destination — this is a macOS app, not iOS, even though iOS/visionOS simulator destinations also appear in the destination list.

CLI equivalents:

```sh
# Build
xcodebuild -project "Performance App/Performance App.xcodeproj" -scheme "Performance App" -destination "platform=macOS" build

# Run all tests
xcodebuild -project "Performance App/Performance App.xcodeproj" -scheme "Performance App" -destination "platform=macOS" test

# Run a single test
xcodebuild -project "Performance App/Performance App.xcodeproj" -scheme "Performance App" -destination "platform=macOS" test \
  -only-testing:"Performance App Tests/SysctlTests/int32ReadsPhysicalCoreCount()"
```

Tests use the **Swift Testing** framework (`import Testing`, `@Test`, `#expect`) — not XCTest. The test target (`Performance App Tests`) is hosted inside the app target.

**Known issue:** running the test target can intermittently crash with `EXC_BREAKPOINT` inside `Runner._applyScopingTraits`, with a different subset of tests failing each run. This reproduces even on trivial tests with no logic connection to each other, and coincided with other environment instability (an Xcode crash, a run that hung on a "Replace" dialog). Treat it as environment/tooling flakiness, not a signal that the affected test's logic is wrong, unless a failure is consistent across repeated runs.

## Architecture

**Navigation shell:** `ContentView.swift` is a `NavigationSplitView` sidebar switching between four independent screens — `CPULoadView`, `MemoryView`, `ProcessesView` (all live-polling), and `HardwareInfoView` (static specs). Each screen owns its own state; there's no shared app-wide model.

**CPU monitoring pipeline** (`CPUMonitor.swift`): a `@MainActor @Observable` class that polls the Mach API `host_processor_info` once a second via an async loop (`start()`, driven by SwiftUI's `.task` lifecycle — no `Timer`, no Combine). Key points for anyone touching this file:
- Per-core usage comes from the *delta* between consecutive tick-count samples, not the raw cumulative counters `host_processor_info` returns.
- Performance/Efficiency core classification is inferred from `hw.perflevel0`/`hw.perflevel1` sysctl counts, combined with the assumption that `host_processor_info` lists efficiency cores before performance cores. That ordering is **not documented by Apple** — it's an empirically-consistent convention on current Apple Silicon chips, not a guaranteed contract. Falls back to `.unspecified` (no badge, no tooltip) whenever the counts don't add up (e.g. Intel Macs).
- The "Total"/"Performance"/"Efficiency" aggregate numbers are **sums** of their member cores' usage, not averages — matching Activity Monitor/`top` convention (e.g. a fully-busy 4-core group reads "400%"). This is intentional; don't "fix" it back to an average.
- `coreTypeLayout(forCoreCount:)` is deliberately `internal` + `nonisolated` (rather than `private`) so it's unit-testable as pure logic without needing to exercise the live polling loop or fight the class's `@MainActor` isolation. Follow this pattern (narrow, explicit seam) rather than loosening access broadly when adding tests for other logic. It `precondition`s that `coreCount >= 0` — the real caller (`refresh()`) derives it from a `UInt32` so this can never fire in production, but don't write a test that passes it a negative value: a failed `precondition` traps the whole process, so there's no way to assert against it in-process (this is exactly how we found the invariant was missing in the first place — a test calling it with `-1` crashed with "Can't construct Array with count < 0").
- `history` is a rolling 60-minute buffer (3600 samples at the 1 Hz polling rate) consumed by the Swift Charts view in `CPULoadView.swift`. The chart's Y-axis scales dynamically to the busiest point currently visible (with headroom); the X-axis is a fixed 60-minute window anchored to the newest sample, not to wall-clock `Date()`.

**Static hardware/GPU info** (`HardwareInfo.swift`, `GPUInfo.swift`): one-shot (not polled) facts gathered via `sysctlbyname` and Metal (`MTLCopyAllDevices`), rendered by `HardwareInfoView.swift` as grouped label/value lists (`HardwareInfoSection`/`HardwareInfoItem`, defined in `HardwareInfo.swift` and reused by `GPUInfo.swift` — don't duplicate these types). Every field is read defensively (`guard`/optional chaining) and simply omitted from the list if the current Mac doesn't report it (e.g. `hw.perflevel1.*` on Intel, or discrete-GPU-only `MTLDevice` properties on Apple Silicon) rather than showing a placeholder or guessing.

**Shared utility:** `Sysctl.swift` wraps `sysctlbyname` for string/int32/uint64 reads, used by both `HardwareInfo` and `CPUMonitor`. It's marked `nonisolated` — without that, call sites from `CPUMonitor`'s `@MainActor`-isolated context, and from synchronous test functions, can't call it.

**Memory monitoring** (`MemoryMonitor.swift`, `MemoryView.swift`): same `@MainActor @Observable` + `.task`-driven polling pattern as `CPUMonitor`, reading `host_statistics64(HOST_VM_INFO64)` once a second — a system-wide Mach API, the same category as `host_processor_info`, not the per-process family below. "Used" is `active + inactive + wired + compressed`, deliberately *not* `total - free`: macOS's aggressive disk caching makes raw "free" memory tiny and misleading. The "Used" bar is a custom segmented view (`SegmentedUsageBar`) colored per kernel category, each with a `.help()` tooltip — mirrors the CPU view's Performance/Efficiency tooltips.

**Per-process CPU monitoring via a privileged helper daemon** (`ProcessHelperClient.swift`, `ProcessHelperXPC.swift`, `ProcessRanking.swift`, `ProcessesView.swift`, plus the separate `Performance App Helper` target): per-process `libproc` calls (`proc_listallpids`, `proc_pid_rusage`) return `EPERM` for the main app, which is an unprivileged, non-root caller — confirmed to fail identically in a snippet, an Xcode Preview, a Debug `⌘R` launch, and a Release Finder launch. There is no per-core/per-thread equivalent of this at all, for anyone or anything — not even Activity Monitor shows "which process is on which core"; Apple treats exact core placement as an internal scheduling detail with no public API (same reasoning as the undocumented P/E core ordering above, one level further).

The working architecture: `Performance App Helper` is a plain command-line-tool target, registered via `SMAppService.daemon(plistName:)` as a `LaunchDaemon` that runs as root, answering `proc_listallpids`/`proc_pid_rusage` requests from the main app over XPC (`NSXPCConnection`, Mach service `com.performanceapp.helper`). This genuinely works with free, local signing — no paid Apple Developer Program membership required. Non-obvious things that cost real debugging time to find, in case this needs touching again:

- **The main app target must not have App Sandbox enabled.** `SMAppService` refuses to register a daemon with "target executable must be sandboxed because the app is sandboxed" if the calling app is sandboxed and the daemon isn't — and a root daemon fundamentally can't be sandboxed to match its caller. If App Sandbox capability is ever re-added (e.g. by Xcode's "Automatically manage signing" regenerating a default entitlements file), registration breaks with a generic "Operation not permitted" that says nothing about sandboxing — the real reason only appears in the system log (see below).
- **A real Team Identifier is required, but a free one is enough.** Pure ad-hoc signing ("Sign to Run Locally", `TeamIdentifier=not set`) fails registration outright with EPERM. Xcode's free "Personal Team" (any Apple ID, via "Setup Signing…" in Signing & Capabilities, no paid enrollment) is sufficient.
- **The two Copy Files build phases must be on the "Performance App" target** — not "Performance App Tests" or "Performance App Helper". Three similarly-named targets in the same dropdown makes this an easy mistake, and the failure mode ("Unable to read plist") doesn't point at the real cause. The phases: the helper executable into destination `Executables` (→ `Contents/MacOS`), and `com.performanceapp.helper.plist` into destination `Wrapper` with subpath `Contents/Library/LaunchDaemons`.
- **BackgroundTaskManagement pins the approved daemon binary by SHA256 checksum.** Rebuilding the helper after it's already registered makes the old approval stop matching the new binary; the daemon then fails to spawn with `last exit code = 78: EX_CONFIG` (visible via `sudo launchctl print system/com.performanceapp.helper`, not through the app itself). Every time the helper's code changes: click "Unregister Helper (dev)" in the Processes view, then fully quit and relaunch the main app to force a fresh `register()` against the current binary.
- **The free signing identity doesn't travel with `git`.** `DEVELOPMENT_TEAM` is a committed build setting, but the actual certificate lives in the local machine's keychain/Xcode account. A fresh clone (or new Apple ID/machine) needs "Setup Signing…" redone for both the "Performance App" and "Performance App Helper" targets before any of this works.
- **`/usr/bin/log show --last Nm --predicate 'eventMessage CONTAINS "performanceapp"'` is the real debugging tool here, not the error Swift sees.** `smd`/`backgroundtaskmanagementd` log the actual reason (sandbox mismatch, checksum mismatch, etc.); the `NSError` that bubbles up through `register()` is a generic, unhelpful "Operation not permitted" in every one of these distinct failure cases.
- `ProcessHelperXPC.swift` (the XPC protocol) and `ProcessRanking.swift` (the delta/ranking math) are duplicated identically in both the "Performance App" and "Performance App Helper" targets — there's no shared-framework wiring between them. Keep both copies in sync when changing either.
- Per-process usage follows the same **sum-not-average**, per-core-unit-of-100% convention as `CPUMonitor` — a process busy on 2 threads simultaneously reads "200%".
- **`rusage_info_v2.ri_user_time`/`ri_system_time` are raw Mach absolute-time ticks, not nanoseconds.** This was the real cause of an early, large (40-100x) discrepancy between the per-process sum and the Cores view's Total — initially misdiagnosed as sampling-interval dilution and as `kernel_task` being unattributed (both real but minor effects, not the dominant one). Confirmed empirically: a controlled 0.5-real-second busy loop reported a raw `ri_user_time` of ~20M, which is ~0.02s if treated as nanoseconds directly but lands in the right ballpark once converted through `mach_timebase_info` (numer=125, denom=3 on Apple Silicon — i.e. 1 tick ≈ 41.67 ns, explaining almost exactly a ~42x understatement). Fixed by converting both fields via `ProcessRanking.nanoseconds(fromMachTicks:timebase:)` before summing in `sampleProcessTimes()`. Don't assume any `libproc`/`rusage` time field is already in nanoseconds without checking — these structs aren't in Apple's indexed Swift/ObjC docs, and ticks-vs-nanoseconds is an easy, silent unit mismatch.
- **The remaining (much smaller) per-process-sum-vs-Total gap is expected, not a bug.** `host_processor_info`'s Total counts every tick on every core, including kernel/interrupt work that per-process `rusage` summation can't attribute to any enumerable process — `kernel_task`/PID 0 in particular does not appear via `proc_listallpids`/`proc_pid_rusage` the way user processes do.
