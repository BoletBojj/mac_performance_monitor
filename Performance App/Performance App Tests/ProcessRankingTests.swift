import Darwin
import Testing
@testable import Performance_App

struct ProcessRankingTests {
    @Test func nanosecondsConvertsRawMachTicksUsingTimebaseRatio() {
        // This Mac's actual ratio (confirmed via mach_timebase_info()):
        // 1 tick = 125/3 ns.
        let timebase = mach_timebase_info(numer: 125, denom: 3)
        #expect(ProcessRanking.nanoseconds(fromMachTicks: 3, timebase: timebase) == 125)
    }

    @Test func nanosecondsIsIdentityWhenNumerEqualsDenom() {
        // Intel Macs report numer == denom (ticks already equal nanoseconds).
        let timebase = mach_timebase_info(numer: 1, denom: 1)
        #expect(ProcessRanking.nanoseconds(fromMachTicks: 123_456, timebase: timebase) == 123_456)
    }

    @Test func topProcessesComputesUsageFromTimeDelta() {
        let current: [pid_t: (name: String, totalCPUTime: UInt64)] = [
            1: (name: "Alpha", totalCPUTime: 2_000_000_000), // 2s of CPU time
            2: (name: "Beta", totalCPUTime: 500_000_000), // 0.5s of CPU time
        ]
        let previous: [pid_t: UInt64] = [1: 1_000_000_000, 2: 0]

        let result = ProcessRanking.topProcesses(from: current, previousTimes: previous, elapsedSeconds: 1, limit: 10)

        let alpha = result.first { $0.name == "Alpha" }
        let beta = result.first { $0.name == "Beta" }
        #expect(alpha?.cpuUsage == 1.0) // 1s of new CPU time over 1s elapsed = 100%
        #expect(beta?.cpuUsage == 0.5)
    }

    @Test func topProcessesSortsDescendingByUsage() {
        let current: [pid_t: (name: String, totalCPUTime: UInt64)] = [
            1: (name: "Low", totalCPUTime: 100_000_000),
            2: (name: "High", totalCPUTime: 900_000_000),
        ]
        let previous: [pid_t: UInt64] = [1: 0, 2: 0]

        let result = ProcessRanking.topProcesses(from: current, previousTimes: previous, elapsedSeconds: 1, limit: 10)

        #expect(result.map(\.name) == ["High", "Low"])
    }

    @Test func topProcessesRespectsLimit() {
        let current: [pid_t: (name: String, totalCPUTime: UInt64)] = Dictionary(
            uniqueKeysWithValues: (0..<20).map { pid_t($0) }.map { ($0, (name: "P\($0)", totalCPUTime: UInt64($0) * 1_000_000)) }
        )
        let previous: [pid_t: UInt64] = Dictionary(uniqueKeysWithValues: current.keys.map { ($0, UInt64(0)) })

        let result = ProcessRanking.topProcesses(from: current, previousTimes: previous, elapsedSeconds: 1, limit: 5)

        #expect(result.count == 5)
    }

    @Test func topProcessesExcludesProcessesMissingFromThePreviousSample() {
        // A process that just started has no previous sample — including it
        // would attribute its entire lifetime CPU time to one tick, wildly
        // overstating usage.
        let current: [pid_t: (name: String, totalCPUTime: UInt64)] = [
            1: (name: "NewProcess", totalCPUTime: 5_000_000_000),
        ]
        let result = ProcessRanking.topProcesses(from: current, previousTimes: [:], elapsedSeconds: 1, limit: 10)
        #expect(result.isEmpty)
    }

    @Test func topProcessesExcludesPidsWhereCpuTimeWentBackwards() {
        // A PID can be reused by a brand-new process between samples; if the
        // "current" time is less than the "previous" time for that pid, it's
        // not really the same process — treat it as unmeasurable, not negative.
        let current: [pid_t: (name: String, totalCPUTime: UInt64)] = [
            1: (name: "Reused", totalCPUTime: 100),
        ]
        let previous: [pid_t: UInt64] = [1: 999_999_999]

        let result = ProcessRanking.topProcesses(from: current, previousTimes: previous, elapsedSeconds: 1, limit: 10)

        #expect(result.isEmpty)
    }

    @Test func topProcessesWithZeroElapsedSecondsReturnsEmpty() {
        let result = ProcessRanking.topProcesses(from: [1: (name: "X", totalCPUTime: 100)], previousTimes: [1: 0], elapsedSeconds: 0, limit: 10)
        #expect(result.isEmpty)
    }

    @Test func topProcessesWithNegativeElapsedSecondsReturnsEmpty() {
        let result = ProcessRanking.topProcesses(from: [1: (name: "X", totalCPUTime: 100)], previousTimes: [1: 0], elapsedSeconds: -1, limit: 10)
        #expect(result.isEmpty)
    }
}
