# Architecture

This document explains *why* the app is built the way it is, not just what each file does (that's what `CLAUDE.md` is for). It's written for a reader who knows software architecture in general but hasn't worked with Swift or macOS before — so alongside the project-specific decisions, it introduces the platform concepts those decisions depend on, with citations to primary sources throughout. A "Findings" section at the end lists concrete things turned up while fact-checking this document against those sources, including one real gap in our own config.

## 1. What the app does

Performance App shows live CPU, memory, and per-process load, plus static hardware/GPU specs — and, since the feature described here, it also shows *history*: charts that cover the last 15 minutes up to the last 24 hours, populated even if the app was closed for most of that window.

That last sentence is the whole reason this architecture is more interesting than "poll some APIs and draw a chart." A normal macOS app only runs while its window is open. To have data from *before the window was open*, something has to be running and recording independently of the app — which immediately raises the two questions this document is about: **what records the data, and how does the app get access to it safely?**

## 2. The big picture

```
┌─────────────────────────────┐        ┌──────────────────────────────┐
│  Performance App             │        │  Performance App Helper       │
│  (your user account,         │  XPC   │  (root, launchd-managed,       │
│   unprivileged, GUI)         │◄──────►│   no UI, runs even when the    │
│                               │        │   app is closed)               │
│  SwiftUI views                │        │  HistoryRecorder (1 Hz loop)   │
│  CPUMonitor / MemoryMonitor   │        │       │                        │
│  (live-only, in this session) │        │       ▼                        │
│  ProcessHelperClient          │        │  HistoryStore (SQLite file)    │
└─────────────────────────────┘        └──────────────────────────────┘
                                                    │
                                                    ▼
                                   /Library/Application Support/
                                     com.performanceapp.helper/
                                           history.sqlite
```

Two separate operating-system processes, started and managed differently, talking over a narrow, defined interface. This split — a long-lived background service plus a thin, disposable UI client — is sometimes called an **agent/daemon architecture**, and it's the same shape as a lot of real infrastructure: a database server and a `psql` client, a Docker daemon and the `docker` CLI, Prometheus's `node_exporter` and its web UI. The daemon owns the data and the hard-won privileges; the client is replaceable and knows nothing about storage.

## 3. macOS concepts this relies on

If you're coming from Linux or Windows, here's the vocabulary translation and the specific APIs this project uses, with links to Apple's own documentation.

### App bundles

A macOS `.app` isn't a single binary — it's a directory ("bundle") with a known internal layout: `Contents/MacOS/` for the executable, `Contents/Info.plist` for metadata, `Contents/Resources/` for assets. Apple's [Bundle Resources documentation](https://developer.apple.com/documentation/BundleResources) and the [`CFBundlePackageType`](https://developer.apple.com/documentation/BundleResources/Information-Property-List/CFBundlePackageType) key (`APPL` for an app, `FMWK` for a framework) describe this structure. It matters here because the helper daemon's LaunchDaemon plist lives *inside* the main app's bundle, at `Contents/Library/LaunchDaemons/` — the whole privileged-helper mechanism depends on the OS being able to find a well-known path inside a well-known bundle layout.

### Processes and privilege separation

Every process on macOS runs as some user. The app runs as *you* — normal privileges, no special access. But reading **any other process's** CPU time (`proc_pid_rusage`, declared in `Shared/SystemSampling.swift`'s `ProcessSampling`) requires root. This isn't a bug or a missing entitlement to request — Apple deliberately gates this information, the same reasoning that stops one app from reading another's memory. The project found this out empirically: the exact same code returns `EPERM` (permission denied) in a Debug build, a Release build, and an Xcode Preview, and returns success only once it's running as root.

This is **privilege separation**: instead of asking "can I make my whole app run as root?" (you can't, cleanly, and you wouldn't want to — any bug in a root GUI app is a security hole), you split off the one piece of code that genuinely needs elevated privilege into its own, minimal process, and have your normal-privilege app talk to *that*. Apple's own documentation describes this exact pattern and names it explicitly: when discussing what to do about functionality a sandboxed app can't perform itself, the guide ["Discovering and diagnosing App Sandbox violations"](https://developer.apple.com/documentation/Security/discovering-and-diagnosing-app-sandbox-violations#Move-potentially-vulnerable-operations-to-a-separate-helper-tool) says to "create separate components" and lists the valid designs: *"An XPC service / A login item / A helper app."* This project uses the third option, a `LaunchDaemon`, which the same family of docs covers under `SMAppService`.

### `launchd`, and the two ways to run in the background

macOS's `launchd` is the process that starts everything else — it's the rough equivalent of `systemd` on Linux or the Windows Service Control Manager. You describe a program to `launchd` with a property list (plist) file, and it decides when to start it, whether to restart it if it crashes, and so on. Apple's [Service Management framework overview](https://developer.apple.com/documentation/ServiceManagement) distinguishes three kinds of helper it can install from inside an app bundle:

- **LoginItems** — an app `launchd` starts when the user logs in, running until they log out or quit it.
- **LaunchAgents** — "processes that run on behalf of the currently logged-in user."
- **LaunchDaemons** — "a stand-alone background process that `launchd` manages on behalf of the user and which runs as root and may run before any users have logged on to the system."

This project uses a LaunchDaemon (`Performance App Helper/com.performanceapp.helper.plist`) because it needs root and needs to exist independent of any logged-in user session. Two keys in that plist control *when* it runs — both documented among the [`launchd` job keys](https://developer.apple.com/documentation/XPC/LAUNCH_JOBKEY_RUNATLOAD) in Apple's XPC reference:
- `RunAtLoad` — start it the moment the system boots, don't wait for anything to ask for it.
- `KeepAlive` — if it crashes, restart it.

Without those two keys (the state this project was in before the history feature), `launchd` only starts the daemon **on demand**, the first time some process tries to open the Mach service it's registered under. That's fine for "answer a question when asked," which is all the daemon used to do. It's not fine for "record continuously in the background" — if nothing asks a question, the daemon never even starts.

**What `launchd` does *not* give you.** It's worth being precise about this because it's easy to conflate "`launchd` runs my daemon" with "`launchd` is where my daemon's data comes from." The job-level keys Apple documents are entirely about *configuration and minimal lifecycle state* — `Label`, `RunAtLoad`, `KeepAlive`, `ProcessType`, resource *limits* like [`ResourceLimit_CPU`](https://developer.apple.com/documentation/XPC/LAUNCH_JOBKEY_RESOURCELIMIT_CPU) (a cap you impose, like `ulimit`, not a measurement), plus exactly two live-state fields: [`PID`](https://developer.apple.com/documentation/XPC/LAUNCH_JOBKEY_PID) and [`LastExitStatus`](https://developer.apple.com/documentation/XPC/LAUNCH_JOBKEY_LASTEXITSTATUS). There is no CPU%, no memory usage, no historical time series anywhere in that vocabulary. `launchd` is a process supervisor, structurally the same relationship to this app as `systemd` is to `node_exporter`: it can tell you a job is running and its last exit code, but has no idea how much CPU that job's workload used last Tuesday. The actual data this app shows — CPU ticks, memory stats, per-process `rusage` — comes from a completely separate kernel subsystem (Mach host statistics and `libproc`), which `launchd` doesn't sit in front of at all.

### `SMAppService`: the modern way to install this

`launchd` has historically needed an administrator to manually drop a plist file into `/Library/LaunchDaemons` — awkward and nothing an app could self-service. [`SMAppService`](https://developer.apple.com/documentation/ServiceManagement/SMAppService) is Apple's current API letting an app *register itself* a LaunchDaemon that already lives inside its own `.app` bundle, and ask the OS to approve and install it:

```swift
// From Apple's own migration guide, "Updating helper executables from earlier versions of macOS"
let daemon = SMAppService.daemon(plistName: "com.example.daemon.plist")
try daemon.register()
```

The project confirmed, the hard way, that this works with a free Apple ID ("Personal Team" signing) and doesn't require a paid Developer Program membership — and found three separate non-obvious failure modes along the way (target mixups, an App Sandbox conflict, and binary-checksum pinning), all documented in `CLAUDE.md`.

### XPC: local RPC, and the option this project *didn't* take

Two separate processes can't just call each other's functions — they don't share memory. **XPC** is Apple's framework for structured local inter-process communication. Apple's [XPC framework overview](https://developer.apple.com/documentation/XPC) is worth reading in full because it lays out three different process environments an XPC service can run in, in a table, and the distinction matters a great deal for this project's design:

| Service Type | Process Environment |
|---|---|
| Launch Agent | One process per logged-in user. |
| Launch Daemon | One systemwide process, root. Can't initiate connections to user processes, only respond. |
| **XPC Service** | *"One process per client of the service, tied to the lifetime of the client. When a client process connects to the service, `launchd` starts a process for the XPC service. When the client process exits, so does the XPC service."* |

That third row is a real, officially-supported, lighter-weight alternative to what this project built — and it's specifically wrong for this project's goal. An "XPC Service" (the bundled, per-client-lifetime kind) would die the moment the app quit, which is exactly the opposite of "record history even when the app is closed." The LaunchDaemon was the correct, deliberate choice given that requirement, not just an arbitrarily more complicated option.

Architecturally, XPC is the same idea as gRPC, a Unix domain socket with a hand-rolled framing format, or Android's Binder/AIDL: a typed contract over an untyped pipe. This project uses the Foundation-level [`NSXPCConnection`](https://developer.apple.com/documentation/Foundation/NSXPCConnection) API, which the XPC overview describes as providing *"a transparent remote method dispatch mechanism between processes"* via a Swift/Objective-C protocol (`Shared/ProcessHelperXPC.swift`'s `ProcessHelperProtocol`). Apple also now ships a newer, non-Foundation Swift API — [`XPCListener`/`XPCSession`](https://developer.apple.com/documentation/XPC#Interprocess-communication) — which this project doesn't use; it's a modern alternative worth exploring if this were rebuilt today, but `NSXPCConnection` remains fully supported and is the more battle-tested, more-documented path for a Foundation-based app like this one.

A detail worth noting because it shows up repeatedly in the code: XPC method replies here are either plain dictionaries (`[String: Any]`) or `Data` (a binary-encoded blob), never a custom Swift class. That's deliberate — passing a custom type over XPC requires explicitly allow-listing its class (`NSXPCInterface.setClasses`), which is easy to get subtly wrong and hard to verify without two live processes to test against. Dictionaries and `Data` need no allow-list, so the project chose them specifically to remove a whole category of possible bugs, at the minor cost of needing to encode/decode manually (`Shared/HistoryCoding.swift`).

Apple's own [performance-tuning guidance for Apple silicon](https://developer.apple.com/documentation/Apple-Silicon/tuning-your-code-s-performance-for-apple-silicon#Configure-Daemons-and-Agents-That-Work-on-Your-Apps-Behalf) independently validates the choice to use XPC rather than, say, a raw socket or a file-watch mechanism: *"Use XPC to communicate with your daemon or launch agent. The system uses context information in XPC messages to track when a daemon or launch agent performs work on behalf of your app. If you use sockets or other IPC mechanisms for communication, the system loses that ability, which might lead to less optimal scheduling decisions."* In other words, XPC isn't just a convenient message-passing library here — the scheduler specifically watches for it to decide how to treat the daemon's CPU time relative to the app's.

### App Sandbox, and why it's off here

Most Mac App Store apps run inside an [App Sandbox](https://developer.apple.com/documentation/Security/app-sandbox) — an OS-enforced box restricting what files, devices, and system calls they can touch, independent of Unix permissions. Apple's framing is blunt about the goal: *"App Sandbox — a requirement for distributing your app on the App Store — limits the scope for an attacker to abuse platform features via your app."* It's a good default. It is, however, incompatible with what this project needs: a sandboxed app cannot register an unsandboxed root daemon, because the daemon would then have more power than its sandboxed launcher, which would defeat the sandbox's purpose. Turning off App Sandbox here is a deliberate, informed trade — not an oversight — made because registering a privileged helper is the explicit goal, and is exactly the scenario Apple's own helper-tool guidance (quoted above) anticipates.

### Code signing, briefly

Every piece of code this project ships — the app, the helper — is cryptographically signed, which is how macOS verifies *"that an app was created by you"* and detects any tampering, accidental or malicious, per Apple's [Code Signing Services overview](https://developer.apple.com/documentation/Security/code-signing-services). Two Apple technotes go deeper if you want the mechanics: [TN3126](https://developer.apple.com/documentation/Technotes/tn3126-inside-code-signing-hashes) explains how signing hashes individual executable pages so tampering with any single page is detectable, and [TN3127](https://developer.apple.com/documentation/Technotes/tn3127-inside-code-signing-requirements) explains *code requirements* — the rules the OS uses to decide whether a piece of running code "is" the code it claims to be. This project's practical takeaway, learned by debugging rather than by reading the technotes first: a daemon's approved binary is pinned by its signature/checksum the moment it's registered, so rebuilding it invalidates that approval until you explicitly re-register (see `CLAUDE.md`'s BackgroundTaskManagement note).

## 4. Swift concepts this relies on

### `@Observable`: state changes without manual publishing

Older Swift UI code (and most Combine-based code) wires state changes through explicit publishers and subscriptions. This project instead uses the [Observation framework](https://developer.apple.com/documentation/Observation), introduced by Swift Evolution proposal [SE-0395](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0395-observability.md): attach `@Observable` to a class (`CPUMonitor`, `MemoryMonitor`, `ProcessHelperClient`) and any SwiftUI view reading its properties automatically re-renders when they change, with no manual publishing step. Apple's own description of the motivation: *"Observation provides a robust, type-safe, and performant implementation of the observer design pattern in Swift... This has the advantages of not directly coupling objects together and allowing implicit distribution of updates across potential multiple observers."*

### `@MainActor`: concurrency isolation enforced by the compiler, not a convention

Swift's concurrency model is built on **actors** — reference types that protect their own mutable state from concurrent access, introduced in [SE-0306](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md). `@MainActor` (from [SE-0316, "Global Actors"](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0316-global-actors.md)) is a specific, singleton actor Apple ties to the main thread, documented as *"a singleton actor whose executor is equivalent to the main dispatch queue."* Marking a class `@MainActor` means the compiler enforces, at compile time, that its methods and properties are only ever touched from the main thread (the one UI updates must happen on) — this isn't a runtime check or a style guideline; a `@MainActor`-isolated method genuinely cannot be called from a background thread without an explicit `await` acknowledging the hop. Apple's own concurrency guide spells out the practical failure mode this prevents: accidentally running expensive work on the main actor causes exactly the kind of UI hang [described here](https://developer.apple.com/documentation/Xcode/improving-app-responsiveness#Avoid-hangs-by-keeping-the-main-thread-free-from-non-UI-work).

### `nonisolated`: the escape hatch, used deliberately

The flip side: some code needs to run *off* the main actor — the helper's background sampling, or a plain synchronous unit test. `nonisolated` on a function (all of `Shared/SystemSampling.swift`, for instance) means "this function has no actor affinity; call it from anywhere." This project's rule of thumb, stated in `CLAUDE.md`: pull pure logic out into a `nonisolated` function so it's callable from the live `@MainActor` view *and* from a synchronous test *and* from the helper's background queue, instead of writing it three times. This is possible without risking data races because such functions are pure and stateless; Swift's [`Sendable`](https://developer.apple.com/documentation/Swift/Sendable) protocol is the compiler's general mechanism for marking "a thread-safe type whose values can be shared across arbitrary concurrent contexts without introducing a risk of data races," and actor types implicitly conform to it.

### Structured concurrency instead of `Timer`

Every polling loop in this app (`CPUMonitor.start()`, `MemoryMonitor.start()`) is a plain `while !Task.isCancelled { ...; try? await Task.sleep(...) }`, launched by SwiftUI's `.task` view modifier. When the view disappears, SwiftUI cancels the task automatically. `async`/`await` itself comes from [SE-0296](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0296-async-await.md), which deliberately scoped itself to *just* the language syntax for suspension, leaving task lifetime to a companion proposal, [SE-0304, "Structured Concurrency"](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md). That proposal's core guarantee is the one this project leans on constantly: *"tasks don't outlive the scope in which they are created... no child task remains running longer than its parent task."* There's no `Timer` to remember to invalidate, no delegate callback, no retain-cycle risk from a timer holding a strong reference to a view — the lifetime of the work is tied to the lifetime of the thing that started it, enforced by the language.

### `DispatchQueue`: the one place this project still uses the older model

The helper's `HistoryRecorder` doesn't use `async`/`await` for its sampling loop — it uses a `DispatchSourceTimer` on a private serial [`DispatchQueue`](https://developer.apple.com/documentation/Dispatch/dispatch-queue), part of Grand Central Dispatch (GCD), the pre-`async`/`await` concurrency model. This is a deliberate exception, not an inconsistency: a plain command-line tool's `main.swift` doesn't have a structured-concurrency root the way a SwiftUI `.task` does, and a single serial queue is a simple, well-understood way to guarantee that the recorder's sampling, buffering, and SQLite access never run concurrently with each other — serial queues, per Apple's documentation, "execute blocks serially in FIFO order," which is exactly the ordering guarantee a single SQLite connection needs.

## 5. The data pipeline: a tiny time-series database

Strip away the Swift/macOS specifics and the history feature is a miniature version of what [Prometheus](https://prometheus.io/docs/prometheus/latest/storage/) does, built from first principles on top of [SQLite](https://www.sqlite.org/wal.html):

```
sample (1 Hz)  →  in-memory buffer  →  batched write (~10 s)  →  SQLite (raw, unaveraged)
                                                                         │
                                        chart asks for a range  ────────┤
                                                                         ▼
                                                      SQL aggregates per time bucket
                                                   (mean, stdDev, min, max — not just mean)
```

Two design decisions here are worth calling out because they generalize well beyond this project:

**Store raw, aggregate on read, not on write.** It would be simpler to pre-compute and store, say, a 1-minute rolling average and throw away the raw samples. The problem: a brief spike gets smoothed into invisibility the moment you average it with 59 quiet seconds. Instead, every raw 1-second sample is kept (until it ages out), and a chart asking for "the last 6 hours" gets the averaging done **at query time**, in SQL, computed fresh from whatever raw data still exists. Prometheus's own storage documentation describes a comparable idea at a much larger scale — it organizes incoming samples into time-bounded blocks and only compacts/downsamples them in the background over time, never discarding raw precision at ingestion. This project's version uses SQL [window functions](https://www.sqlite.org/windowfunctions.html) (`PARTITION BY`, `ROW_NUMBER()`) and [`UPSERT`](https://sqlite.org/lang_upsert.html) (`INSERT ... ON CONFLICT DO UPDATE`) to do the equivalent aggregation and peak-tracking directly in SQLite, rather than in a dedicated time-series engine.

**A bare mean still isn't enough — carry the shape of the data, not just its center.** Even without pre-averaging, a chart covering 24 hours still has to compress ~86,000 raw samples down to a few hundred points to render sensibly. If that compression keeps *only* a mean, a spike inside a 2-minute bucket still disappears into the average of that bucket. `BucketStats` instead keeps mean, standard deviation, min, and max per bucket — computed cheaply via running sums (`SUM(x)`, `SUM(x·x)`) rather than storing every sample twice — so the chart can draw a faint min/max envelope behind the mean line and a spike stays visible no matter how far you zoom out.

A few smaller patterns round this out:
- **Buffered writes, and [WAL mode](https://www.sqlite.org/wal.html).** The daemon samples every second but only writes to disk roughly every 10 seconds, batched into one transaction — a classic throughput-over-latency trade so a background daemon that's supposed to be invisible doesn't spend its life doing disk I/O. The database also runs in SQLite's Write-Ahead Log mode, which SQLite's own documentation notes is "significantly faster in most scenarios" and lets readers and a writer proceed concurrently without blocking each other — relevant here because the recorder is writing at the same time a chart might be querying.
- **Retention via a moving cutoff, recomputed each prune**, not a one-time deadline — `max(now − 24h, boot time)`, so a reboot immediately discards the previous boot's data rather than waiting for it to age out naturally.
- **An exemption table for all-time records.** The `peaks` table is deliberately *not* subject to the retention cutoff above, updated via the same SQLite `UPSERT` syntax described above (`ON CONFLICT(metric) DO UPDATE ... WHERE excluded.value > peaks.value`) — an all-time-high value would be meaningless if it could silently expire. This is the general pattern of having two different retention policies for two different *kinds* of derived data, rather than one blanket rule for everything.
- **Graceful degradation.** Every chart falls back to a local, in-memory-only history (`CPUMonitor.history`/`MemoryMonitor.history`) if the daemon is unreachable. The UI never shows a broken or empty chart just because the background piece isn't available yet — it shows a strictly worse, but still working, version of itself.

## 6. The three layers, and where to find them

- **`Shared/`** — pure domain logic and thin platform-API wrappers: reading CPU ticks, reading memory stats, the SQLite access layer, the math (`BucketStats`'s variance calculation), the XPC contract. Nothing here knows whether it's running inside the UI app or the background daemon, which is exactly why it's safe to compile into both. This is the layer with the most unit tests, because it's the layer with no UI and no live system state to fight.
- **`Performance App Helper/`** — orchestration only. `HistoryRecorder` decides *when* to call the `Shared/` sampling functions and *when* to flush/prune; `main.swift` wires the XPC listener to it. If you're looking for "what runs on a timer and writes to the database," it's here.
- **`Performance App/`** — the SwiftUI client. Owns nothing persistent; every screen's state is rebuilt from scratch each launch, either by asking the daemon for history or by starting a fresh live poll. If you're looking for "how does a value end up drawn on screen," it's here.

The dependency direction only ever points one way: the app depends on the daemon's XPC contract; the daemon has no idea the app exists. That's what makes "the app isn't running" a non-event for the daemon instead of a crash.

## 7. Honest limitations

- The daemon only starts existing at all once the app has been launched *at least once* to call `register()`. There's no way around this — it's how `SMAppService` is designed to work, specifically so a user always has to have knowingly installed the thing creating a background daemon.
- Every helper rebuild during development currently requires an explicit "Unregister Helper (dev)" + quit + relaunch, because macOS pins the approved daemon binary by checksum (see `CLAUDE.md` for the full story). This is a development-workflow cost, not a design flaw — it's the same checksum pinning that protects a real user from a background daemon silently swapping itself for a different binary after approval.
- Sleep, or any stretch where the daemon isn't running, shows up as a visible gap in the charts rather than a smoothed-over line — a deliberate choice (see `HistoryGapSegmentation`) to never visually imply data that doesn't exist.

## 8. Findings from checking these references

Writing this document meant checking every nontrivial claim against Apple's, SQLite's, or Swift Evolution's own documentation rather than relying on memory. Two things turned up that are worth recording:

1. **Fixed: `com.performanceapp.helper.plist` was missing the `ProcessType` key.** Apple's [Apple Silicon performance-tuning guide](https://developer.apple.com/documentation/Apple-Silicon/tuning-your-code-s-performance-for-apple-silicon#Configure-Daemons-and-Agents-That-Work-on-Your-Apps-Behalf) states plainly: *"Always include the `ProcessType` key in your daemon or launch agent's `Info.plist` file. The system uses that key to determine your daemon's purpose and adjust its available resources accordingly."* Added `ProcessType = Adaptive`, signaling to the scheduler that the daemon's resource needs should scale with how actively the app is using it, rather than running at a fixed, undifferentiated priority continuously in the background.
2. **Two valid alternatives we deliberately didn't take**, confirmed rather than assumed: Apple's XPC overview documents a lighter-weight "XPC Service" type (bundled, lazily started and stopped per client, dying with its client) as a first-class alternative to a LaunchDaemon — wrong for this project specifically because history needs to survive the app quitting, but worth knowing it exists for anything that doesn't need that. Separately, Apple now ships a newer Swift-native `XPCListener`/`XPCSession` API alongside the older Foundation `NSXPCConnection` API this project uses; both are current and supported, and `NSXPCConnection` was the better fit here purely because it's the more established, more-documented path for a Foundation-based app.
