import Foundation
import Darwin

/// Pure delta/ranking logic, independent of live process enumeration. Lives
/// in Shared/ so it's both unit-testable from the app target and usable by
/// the helper, which is where it runs against live data.
nonisolated enum ProcessRanking {
    /// `rusage_info_v2.ri_user_time`/`ri_system_time` are raw Mach absolute-time
    /// ticks, not nanoseconds — confirmed empirically (a controlled 0.5s busy
    /// loop reported ~20M raw units, i.e. ~41.67x too small to be nanoseconds
    /// directly, matching this Mac's `mach_timebase_info` numer/denom ratio of
    /// 125/3). Multiply before dividing: tick counts stay small enough
    /// relative to `UInt64` that overflow isn't a practical concern (a process
    /// would need ~193 years of accumulated CPU time to overflow here).
    static func nanoseconds(fromMachTicks ticks: UInt64, timebase: mach_timebase_info) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    static func topProcesses(
        from currentTimes: [pid_t: (name: String, totalCPUTime: UInt64)],
        previousTimes: [pid_t: UInt64],
        elapsedSeconds: TimeInterval,
        limit: Int
    ) -> [(name: String, cpuUsage: Double)] {
        guard elapsedSeconds > 0 else { return [] }
        let elapsedNanoseconds = elapsedSeconds * 1_000_000_000

        let usages: [(name: String, cpuUsage: Double)] = currentTimes.compactMap { pid, info in
            // Missing from the previous sample (just launched) or time that
            // went backwards (pid reused by an unrelated new process) can't
            // be attributed to a rate over this interval — skip rather than
            // report a misleading number.
            guard let previous = previousTimes[pid], info.totalCPUTime >= previous else { return nil }
            let busyNanoseconds = Double(info.totalCPUTime - previous)
            return (name: info.name, cpuUsage: busyNanoseconds / elapsedNanoseconds)
        }

        return Array(usages.sorted { $0.cpuUsage > $1.cpuUsage }.prefix(limit))
    }
}
