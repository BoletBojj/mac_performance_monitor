import Foundation
import Darwin

enum CPUCoreType: Equatable {
    case performance
    case efficiency
    case unspecified // no documented P/E split on this Mac (e.g. Intel)

    func label(index: Int) -> String {
        switch self {
        case .performance: "Performance Core \(index)"
        case .efficiency: "Efficiency Core \(index)"
        case .unspecified: "Core \(index)"
        }
    }

    var explanation: String? {
        switch self {
        case .performance:
            "Performance (P) cores run at higher clock speed for demanding, latency-sensitive work — compiling, gaming, video export — at the cost of more power draw and heat."
        case .efficiency:
            "Efficiency (E) cores run at lower clock speed to save power and reduce heat. macOS schedules background and low-priority work here, like indexing or syncing."
        case .unspecified:
            nil
        }
    }
}

struct CPUCoreLoad: Identifiable, Equatable {
    let id: Int
    let type: CPUCoreType
    let displayIndex: Int // position within its core type, for the row label
    var usage: Double // 0...1
}

/// One point in the load-over-time chart. `date` (not a sample count) is the
/// source of truth for the x-axis, since the sampling loop's `Task.sleep`
/// interval is a target, not a hardware-guaranteed tick.
struct CPULoadSample: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let overall: Double // 0...coreCount — sum of every core's usage, not an average
    let performance: Double? // 0...performanceCoreCount
    let efficiency: Double? // 0...efficiencyCoreCount
}

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

    private let historyWindow: TimeInterval = 60 * 60 // keep the last 60 minutes, regardless of sampling interval
    private let minimumSamplingInterval: TimeInterval = 0.1 // floor against a zero/negative interval spinning the loop

    private var previousTicks: [UInt32] = []
    private var coreTypes: [CPUCoreType] = []

    /// Runs until the enclosing task is cancelled (e.g. by SwiftUI's `.task` modifier).
    func start() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(max(samplingInterval, minimumSamplingInterval)))
        }
    }

    private func refresh() {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
        guard result == KERN_SUCCESS, let cpuInfo else { return }
        defer {
            let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), size)
        }

        let coreCount = Int(numCPUs)
        let statesPerCore = Int(CPU_STATE_MAX)
        var newTicks = [UInt32](repeating: 0, count: coreCount * 4)
        var newLoads: [CPUCoreLoad] = []
        newLoads.reserveCapacity(coreCount)
        var overallUsageSum = 0.0
        var performanceUsageSum = 0.0
        var efficiencyUsageSum = 0.0

        if coreTypes.count != coreCount {
            let layout = Self.coreTypeLayout(forCoreCount: coreCount)
            coreTypes = layout.types
            performanceCoreCount = layout.performanceCount
            efficiencyCoreCount = layout.efficiencyCount
        }
        var performanceSeen = 0
        var efficiencySeen = 0

        for core in 0..<coreCount {
            let type = coreTypes[core]
            let base = core * statesPerCore
            let user = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_NICE)])

            let tickBase = core * 4
            newTicks[tickBase] = user
            newTicks[tickBase + 1] = system
            newTicks[tickBase + 2] = idle
            newTicks[tickBase + 3] = nice

            var usage = 0.0
            if previousTicks.count == newTicks.count {
                // Ticks are cumulative counters, so usage comes from the delta
                // between this sample and the previous one, not the raw totals.
                let userDelta = Double(user &- previousTicks[tickBase])
                let systemDelta = Double(system &- previousTicks[tickBase + 1])
                let idleDelta = Double(idle &- previousTicks[tickBase + 2])
                let niceDelta = Double(nice &- previousTicks[tickBase + 3])
                let total = userDelta + systemDelta + idleDelta + niceDelta
                let active = userDelta + systemDelta + niceDelta
                if total > 0 {
                    usage = active / total
                }
                // "Total" sums each core's usage rather than averaging it, so
                // it reads the same way Activity Monitor's aggregate CPU% does:
                // a fully busy 4-core group reads 400%, not 100%.
                overallUsageSum += usage
                switch type {
                case .performance:
                    performanceUsageSum += usage
                case .efficiency:
                    efficiencyUsageSum += usage
                case .unspecified:
                    break
                }
            }

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

            newLoads.append(CPUCoreLoad(id: core, type: type, displayIndex: displayIndex, usage: usage))
        }

        previousTicks = newTicks
        coreLoads = newLoads
        self.coreCount = coreCount
        overallUsage = overallUsageSum
        performanceUsage = performanceCoreCount > 0 ? performanceUsageSum : nil
        efficiencyUsage = efficiencyCoreCount > 0 ? efficiencyUsageSum : nil

        let now = Date()
        history.append(CPULoadSample(date: now, overall: overallUsage, performance: performanceUsage, efficiency: efficiencyUsage))
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

    struct CoreTypeLayout: Equatable {
        let types: [CPUCoreType]
        let performanceCount: Int
        let efficiencyCount: Int
    }

    /// `host_processor_info` doesn't document which indices are which core
    /// type, but on every current Apple silicon chip it lists efficiency
    /// cores first, then performance cores — matching the counts reported by
    /// `hw.perflevel0`/`hw.perflevel1`. If those counts don't add up to the
    /// reported core count (e.g. an Intel Mac with a single core tier), every
    /// core is left unspecified instead of guessing.
    ///
    /// Internal (not private) so it's unit-testable as pure logic, independent
    /// of the live `host_processor_info` polling loop.
    nonisolated static func coreTypeLayout(forCoreCount coreCount: Int) -> CoreTypeLayout {
        precondition(coreCount >= 0, "core count can't be negative")
        guard
            let performanceCores = Sysctl.int32("hw.perflevel0.physicalcpu").map(Int.init),
            let efficiencyCores = Sysctl.int32("hw.perflevel1.physicalcpu").map(Int.init),
            performanceCores + efficiencyCores == coreCount
        else {
            return CoreTypeLayout(types: Array(repeating: .unspecified, count: coreCount), performanceCount: 0, efficiencyCount: 0)
        }
        let types = Array(repeating: CPUCoreType.efficiency, count: efficiencyCores)
            + Array(repeating: CPUCoreType.performance, count: performanceCores)
        return CoreTypeLayout(types: types, performanceCount: performanceCores, efficiencyCount: efficiencyCores)
    }
}
