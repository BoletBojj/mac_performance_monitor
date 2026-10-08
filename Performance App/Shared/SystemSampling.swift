import Foundation
import Darwin

// Raw system sampling shared by the app (live views) and the helper
// (background history recording). Everything here is `nonisolated`: the app
// target defaults to MainActor isolation, but the helper calls these from a
// background queue.

nonisolated enum CPUCoreType: Equatable {
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

nonisolated struct CoreTypeLayout: Equatable {
    let types: [CPUCoreType]
    let performanceCount: Int
    let efficiencyCount: Int
}

/// Cumulative per-core tick counters as reported by `host_processor_info`.
nonisolated struct CPUCoreTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

nonisolated struct CPUAggregate: Equatable {
    let perCore: [Double] // 0...1 each
    let overall: Double // sum of perCore, not an average
    let performance: Double? // nil when this Mac has no P/E split
    let efficiency: Double?
}

nonisolated enum CPUSampling {
    static func readTicks() -> [CPUCoreTicks]? {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
        guard result == KERN_SUCCESS, let cpuInfo else { return nil }
        defer {
            let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), size)
        }

        let statesPerCore = Int(CPU_STATE_MAX)
        return (0..<Int(numCPUs)).map { core in
            let base = core * statesPerCore
            return CPUCoreTicks(
                user: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    /// Usage comes from the delta between two cumulative samples, not the raw
    /// totals. Returns nil when the samples aren't comparable (first sample,
    /// or the core count changed). Wrapping subtraction keeps a counter that
    /// rolled over past `UInt32.max` from producing a huge bogus delta.
    static func aggregate(previous: [CPUCoreTicks], current: [CPUCoreTicks], layout: CoreTypeLayout) -> CPUAggregate? {
        guard !current.isEmpty, previous.count == current.count, layout.types.count == current.count else { return nil }

        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        var performance = 0.0
        var efficiency = 0.0

        for (index, (old, new)) in zip(previous, current).enumerated() {
            let active = Double(new.user &- old.user) + Double(new.system &- old.system) + Double(new.nice &- old.nice)
            let total = active + Double(new.idle &- old.idle)
            let usage = total > 0 ? active / total : 0
            perCore.append(usage)
            switch layout.types[index] {
            case .performance: performance += usage
            case .efficiency: efficiency += usage
            case .unspecified: break
            }
        }

        return CPUAggregate(
            perCore: perCore,
            overall: perCore.reduce(0, +),
            performance: layout.performanceCount > 0 ? performance : nil,
            efficiency: layout.efficiencyCount > 0 ? efficiency : nil
        )
    }

    /// `host_processor_info` doesn't document which indices are which core
    /// type, but on every current Apple silicon chip it lists efficiency
    /// cores first, then performance cores — matching the counts reported by
    /// `hw.perflevel0`/`hw.perflevel1`. If those counts don't add up to the
    /// reported core count (e.g. an Intel Mac), every core is left
    /// unspecified instead of guessing.
    static func coreTypeLayout(forCoreCount coreCount: Int) -> CoreTypeLayout {
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

nonisolated struct MemorySnapshot: Equatable {
    let totalBytes: UInt64
    let freeBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let swapUsedBytes: UInt64
    let swapTotalBytes: UInt64

    /// Active + inactive + wired + compressed — deliberately *not*
    /// `totalBytes - freeBytes`. macOS caches aggressively, so "free" is
    /// often tiny even when plenty of memory is actually available.
    var usedBytes: UInt64 {
        activeBytes + inactiveBytes + wiredBytes + compressedBytes
    }

    var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

nonisolated enum MemorySampling {
    /// System-wide virtual memory statistics via `host_statistics64` — not
    /// privilege-gated, unlike the per-process `libproc` calls below.
    static func readSnapshot() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        guard let totalBytes = Sysctl.uint64("hw.memsize") else { return nil }

        let pageSize = UInt64(vm_page_size)

        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0)

        return MemorySnapshot(
            totalBytes: totalBytes,
            freeBytes: UInt64(stats.free_count) * pageSize,
            activeBytes: UInt64(stats.active_count) * pageSize,
            inactiveBytes: UInt64(stats.inactive_count) * pageSize,
            wiredBytes: UInt64(stats.wire_count) * pageSize,
            compressedBytes: UInt64(stats.compressor_page_count) * pageSize,
            swapUsedBytes: swapResult == 0 ? UInt64(swapUsage.xsu_used) : 0,
            swapTotalBytes: swapResult == 0 ? UInt64(swapUsage.xsu_total) : 0
        )
    }
}

nonisolated enum ProcessSampling {
    /// Cumulative CPU time per process, in nanoseconds. Only succeeds when
    /// running as root (the helper); returns `[:]` with EPERM in the app.
    static func sampleProcessTimes() -> [pid_t: (name: String, totalCPUTime: UInt64)] {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)

        let capacity = 4096
        var pids = [pid_t](repeating: 0, count: capacity)
        let returnedBytes = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(capacity * MemoryLayout<pid_t>.size))
        }
        guard returnedBytes > 0 else { return [:] }
        let pidCount = min(Int(returnedBytes) / MemoryLayout<pid_t>.size, capacity)

        var result: [pid_t: (name: String, totalCPUTime: UInt64)] = [:]
        // No `pid > 0` filter: `.prefix(pidCount)` already bounds this to the
        // populated slots, and such a filter would wrongly drop PID 0.
        for pid in pids.prefix(pidCount) {
            var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { continue }

            var usage = rusage_info_v2()
            let rusageResult = withUnsafeMutablePointer(to: &usage) { structPtr -> Int32 in
                structPtr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, reboundPtr)
                }
            }
            guard rusageResult == 0 else { continue }

            let userTime = ProcessRanking.nanoseconds(fromMachTicks: usage.ri_user_time, timebase: timebase)
            let systemTime = ProcessRanking.nanoseconds(fromMachTicks: usage.ri_system_time, timebase: timebase)
            result[pid] = (name: String(cString: nameBuffer), totalCPUTime: userTime + systemTime)
        }
        return result
    }
}

nonisolated enum SystemClock {
    /// Wall-clock time the machine last booted, from `kern.boottime`.
    static func bootTime() -> Date? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0, bootTime.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000)
    }
}
