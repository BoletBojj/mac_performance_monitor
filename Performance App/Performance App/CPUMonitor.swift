import Foundation

struct CPUCoreLoad: Identifiable, Equatable {
    let id: Int
    let type: CPUCoreType
    let displayIndex: Int // position within its core type, for the row label
    var usage: Double // 0...1
}

/// One point in the app's local (fallback) load-over-time chart. `date` (not
/// a sample count) is the source of truth for the x-axis, since the sampling
/// loop's `Task.sleep` interval is a target, not a hardware-guaranteed tick.
struct CPULoadSample: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let overall: Double // 0...coreCount — sum of every core's usage, not an average
    let performance: Double? // 0...performanceCoreCount
    let efficiency: Double? // 0...efficiencyCoreCount
}

/// Live per-core readings for the CPU view. The long-term chart comes from
/// the helper's recorded history; `history` here is only the fallback used
/// when the helper isn't available.
@MainActor
@Observable
final class CPUMonitor {
    private(set) var coreLoads: [CPUCoreLoad] = []
    private(set) var overallUsage: Double = 0 // 0...coreCount, e.g. 2.3 means "2.3 cores' worth of work"
    private(set) var performanceUsage: Double? // 0...performanceCoreCount; nil when this Mac has no P/E split
    private(set) var efficiencyUsage: Double? // 0...efficiencyCoreCount
    private(set) var history: [CPULoadSample] = []
    private(set) var performanceCoreCount = 0
    private(set) var efficiencyCoreCount = 0
    private(set) var coreCount = 0

    /// User-adjustable from `CPULoadView`, in seconds. Read fresh at the top
    /// of every loop iteration, so changing it takes effect on the very next
    /// sleep without needing to restart the polling task.
    var samplingInterval: TimeInterval = 1

    private let historyWindow: TimeInterval = 60 * 60
    private let minimumSamplingInterval: TimeInterval = 0.1 // floor against a zero/negative interval spinning the loop

    private var previousTicks: [CPUCoreTicks] = []
    private var layout = CoreTypeLayout(types: [], performanceCount: 0, efficiencyCount: 0)

    /// Runs until the enclosing task is cancelled (e.g. by SwiftUI's `.task` modifier).
    func start() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(max(samplingInterval, minimumSamplingInterval)))
        }
    }

    private func refresh() {
        guard let ticks = CPUSampling.readTicks() else { return }

        if layout.types.count != ticks.count {
            layout = CPUSampling.coreTypeLayout(forCoreCount: ticks.count)
            performanceCoreCount = layout.performanceCount
            efficiencyCoreCount = layout.efficiencyCount
        }
        coreCount = ticks.count

        let aggregate = CPUSampling.aggregate(previous: previousTicks, current: ticks, layout: layout)
        previousTicks = ticks

        var performanceSeen = 0
        var efficiencySeen = 0
        coreLoads = layout.types.enumerated().map { core, type in
            let displayIndex: Int
            switch type {
            case .performance:
                displayIndex = performanceSeen
                performanceSeen += 1
            case .efficiency:
                displayIndex = efficiencySeen
                efficiencySeen += 1
            case .unspecified:
                displayIndex = core
            }
            return CPUCoreLoad(id: core, type: type, displayIndex: displayIndex, usage: aggregate?.perCore[core] ?? 0)
        }

        // The very first sample has nothing to diff against; skip it rather
        // than recording a fake 0% point.
        guard let aggregate else { return }
        overallUsage = aggregate.overall
        performanceUsage = aggregate.performance
        efficiencyUsage = aggregate.efficiency

        let now = Date()
        history.append(CPULoadSample(date: now, overall: aggregate.overall, performance: aggregate.performance, efficiency: aggregate.efficiency))
        history = Self.trimmedHistory(history, keeping: historyWindow, relativeTo: now)
    }

    /// Drops samples older than `window`, measured from `now` — not a fixed
    /// sample count, so the kept duration stays correct regardless of
    /// `samplingInterval`. Internal + `nonisolated` so it's testable with
    /// synthetic timestamps, without waiting on real wall-clock time.
    nonisolated static func trimmedHistory(
        _ history: [CPULoadSample],
        keeping window: TimeInterval,
        relativeTo now: Date
    ) -> [CPULoadSample] {
        let oldestKept = now.addingTimeInterval(-window)
        return history.filter { $0.date >= oldestKept }
    }
}
