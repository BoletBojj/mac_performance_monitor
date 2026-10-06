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

**Navigation shell:** `ContentView.swift` is a `NavigationSplitView` sidebar switching between two independent screens — `CPULoadView` (live monitoring) and `HardwareInfoView` (static specs). Each screen owns its own state; there's no shared app-wide model.

**CPU monitoring pipeline** (`CPUMonitor.swift`): a `@MainActor @Observable` class that polls the Mach API `host_processor_info` once a second via an async loop (`start()`, driven by SwiftUI's `.task` lifecycle — no `Timer`, no Combine). Key points for anyone touching this file:
- Per-core usage comes from the *delta* between consecutive tick-count samples, not the raw cumulative counters `host_processor_info` returns.
- Performance/Efficiency core classification is inferred from `hw.perflevel0`/`hw.perflevel1` sysctl counts, combined with the assumption that `host_processor_info` lists efficiency cores before performance cores. That ordering is **not documented by Apple** — it's an empirically-consistent convention on current Apple Silicon chips, not a guaranteed contract. Falls back to `.unspecified` (no badge, no tooltip) whenever the counts don't add up (e.g. Intel Macs).
- The "Total"/"Performance"/"Efficiency" aggregate numbers are **sums** of their member cores' usage, not averages — matching Activity Monitor/`top` convention (e.g. a fully-busy 4-core group reads "400%"). This is intentional; don't "fix" it back to an average.
- `coreTypeLayout(forCoreCount:)` is deliberately `internal` + `nonisolated` (rather than `private`) so it's unit-testable as pure logic without needing to exercise the live polling loop or fight the class's `@MainActor` isolation. Follow this pattern (narrow, explicit seam) rather than loosening access broadly when adding tests for other logic. It `precondition`s that `coreCount >= 0` — the real caller (`refresh()`) derives it from a `UInt32` so this can never fire in production, but don't write a test that passes it a negative value: a failed `precondition` traps the whole process, so there's no way to assert against it in-process (this is exactly how we found the invariant was missing in the first place — a test calling it with `-1` crashed with "Can't construct Array with count < 0").
- `history` is a rolling 60-minute buffer (3600 samples at the 1 Hz polling rate) consumed by the Swift Charts view in `CPULoadView.swift`. The chart's Y-axis scales dynamically to the busiest point currently visible (with headroom); the X-axis is a fixed 60-minute window anchored to the newest sample, not to wall-clock `Date()`.

**Static hardware/GPU info** (`HardwareInfo.swift`, `GPUInfo.swift`): one-shot (not polled) facts gathered via `sysctlbyname` and Metal (`MTLCopyAllDevices`), rendered by `HardwareInfoView.swift` as grouped label/value lists (`HardwareInfoSection`/`HardwareInfoItem`, defined in `HardwareInfo.swift` and reused by `GPUInfo.swift` — don't duplicate these types). Every field is read defensively (`guard`/optional chaining) and simply omitted from the list if the current Mac doesn't report it (e.g. `hw.perflevel1.*` on Intel, or discrete-GPU-only `MTLDevice` properties on Apple Silicon) rather than showing a placeholder or guessing.

**Shared utility:** `Sysctl.swift` wraps `sysctlbyname` for string/int32/uint64 reads, used by both `HardwareInfo` and `CPUMonitor`. It's marked `nonisolated` — without that, call sites from `CPUMonitor`'s `@MainActor`-isolated context, and from synchronous test functions, can't call it.

## Explored and abandoned: per-process / per-core CPU attribution

Two related features were prototyped and deliberately removed — don't re-attempt either without new information:

- **"Which process/thread is running on which core"** has no public macOS API at all. Not even Activity Monitor shows this; Apple treats exact core placement as an internal scheduling detail (same reasoning as the undocumented P/E core ordering above, just one level further).
- **"Top processes by CPU usage"** (no per-core breakdown, just an Activity-Monitor-style ranked list) *is* normally implementable with public APIs (`proc_listallpids` + `proc_pid_rusage` from libproc, diffing cumulative CPU time between samples the same way `CPUMonitor` diffs tick counts). It was fully implemented and worked technically, but `proc_listallpids` itself returned `EPERM` in every context tested on this machine/OS — a plain snippet, an Xcode Preview, a Debug `⌘R` launch, and a Release Finder-launch, all identical. Adding `com.apple.security.cs.debugger` made no difference (that entitlement governs `task_for_pid()`/debugger-level access, not this lighter proc-info family, so that result was expected in hindsight). The remaining options are both out of scope for this project: running the whole app as root, or a proper privileged XPC helper authorized via Authorization Services to shell out to `powermetrics`.
