import Testing
@testable import Performance_App

struct CPUSamplingTests {
    private func layout(efficiency: Int, performance: Int) -> CoreTypeLayout {
        CoreTypeLayout(
            types: Array(repeating: .efficiency, count: efficiency) + Array(repeating: .performance, count: performance),
            performanceCount: performance,
            efficiencyCount: efficiency
        )
    }

    @Test func firstSampleHasNoPreviousDataAndReturnsNil() {
        // There's nothing to diff against yet, so this must not be reported
        // as a (misleadingly precise) 0% reading.
        let current = [CPUCoreTicks(user: 100, system: 50, idle: 850, nice: 0)]
        let result = CPUSampling.aggregate(previous: [], current: current, layout: layout(efficiency: 1, performance: 0))
        #expect(result == nil)
    }

    @Test func coreCountChangeBetweenSamplesReturnsNil() {
        let previous = [CPUCoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let current = [
            CPUCoreTicks(user: 0, system: 0, idle: 0, nice: 0),
            CPUCoreTicks(user: 0, system: 0, idle: 0, nice: 0),
        ]
        let result = CPUSampling.aggregate(previous: previous, current: current, layout: layout(efficiency: 2, performance: 0))
        #expect(result == nil)
    }

    @Test func usageComesFromTheDeltaNotTheCumulativeTotal() {
        // Core has accumulated 1000 idle ticks already; only the 100 new
        // active ticks since the last sample should count.
        let previous = [CPUCoreTicks(user: 500, system: 0, idle: 9000, nice: 0)]
        let current = [CPUCoreTicks(user: 600, system: 0, idle: 9000, nice: 0)] // +100 user, +0 idle
        let result = CPUSampling.aggregate(previous: previous, current: current, layout: layout(efficiency: 1, performance: 0))
        #expect(result?.perCore[0] == 1.0) // all new ticks were active
    }

    @Test func overallIsTheSumOfPerCoreUsageNotTheAverage() {
        // Two fully-busy cores should read 200%, matching Activity
        // Monitor/`top` convention — not averaged down to 100%.
        let previous = [
            CPUCoreTicks(user: 0, system: 0, idle: 0, nice: 0),
            CPUCoreTicks(user: 0, system: 0, idle: 0, nice: 0),
        ]
        let current = [
            CPUCoreTicks(user: 100, system: 0, idle: 0, nice: 0),
            CPUCoreTicks(user: 100, system: 0, idle: 0, nice: 0),
        ]
        let result = CPUSampling.aggregate(previous: previous, current: current, layout: layout(efficiency: 2, performance: 0))
        #expect(result?.overall == 2.0)
    }

    @Test func splitsUsageIntoPerformanceAndEfficiencySums() {
        let previous = [
            CPUCoreTicks(user: 0, system: 0, idle: 0, nice: 0), // efficiency
            CPUCoreTicks(user: 0, system: 0, idle: 0, nice: 0), // performance
            CPUCoreTicks(user: 0, system: 0, idle: 0, nice: 0), // performance
        ]
        let current = [
            CPUCoreTicks(user: 50, system: 0, idle: 50, nice: 0), // efficiency: 50%
            CPUCoreTicks(user: 100, system: 0, idle: 0, nice: 0), // performance: 100%
            CPUCoreTicks(user: 100, system: 0, idle: 0, nice: 0), // performance: 100%
        ]
        let result = CPUSampling.aggregate(previous: previous, current: current, layout: layout(efficiency: 1, performance: 2))
        #expect(result?.efficiency == 0.5)
        #expect(result?.performance == 2.0)
        #expect(result?.overall == 2.5)
    }

    @Test func noCoresOfAGivenTypeReportsNilForThatAggregate() {
        let previous = [CPUCoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let current = [CPUCoreTicks(user: 100, system: 0, idle: 0, nice: 0)]
        let result = CPUSampling.aggregate(previous: previous, current: current, layout: layout(efficiency: 1, performance: 0))
        #expect(result?.performance == nil)
    }

    @Test func wraparoundCounterUsesWrappingSubtractionInsteadOfCrashing() {
        // UInt32 ticks can roll over past .max during very long uptimes.
        // Wrapping subtraction (`&-`) still produces the correct small delta
        // instead of trapping or producing a huge bogus value.
        let previous = [CPUCoreTicks(user: UInt32.max - 10, system: 0, idle: 1000, nice: 0)]
        let current = [CPUCoreTicks(user: 9, system: 0, idle: 1000, nice: 0)] // wrapped past .max, +20 user ticks
        let result = CPUSampling.aggregate(previous: previous, current: current, layout: layout(efficiency: 1, performance: 0))
        #expect(result?.perCore[0] == 1.0) // 20 active ticks, 0 new idle ticks
    }

    @Test func zeroTotalDeltaReportsZeroUsageInsteadOfDividingByZero() {
        let ticks = [CPUCoreTicks(user: 5, system: 5, idle: 90, nice: 0)]
        let result = CPUSampling.aggregate(previous: ticks, current: ticks, layout: layout(efficiency: 1, performance: 0))
        #expect(result?.perCore[0] == 0)
    }

    @Test func coreTypeLayoutMismatchedCoreCountFallsBackToUnspecified() {
        // No real Mac reports 999 cores, so the P/E counts from sysctl can
        // never add up to this — exercises the fallback path without
        // depending on the test machine's actual chip.
        let layout = CPUSampling.coreTypeLayout(forCoreCount: 999)
        #expect(layout.performanceCount == 0)
        #expect(layout.efficiencyCount == 0)
        #expect(layout.types.count == 999)
        #expect(layout.types.allSatisfy { $0 == .unspecified })
    }
}
