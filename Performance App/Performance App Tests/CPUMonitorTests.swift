import Foundation
import Testing
@testable import Performance_App

struct CPUMonitorTests {
    @Test func mismatchedCoreCountFallsBackToUnspecified() {
        // No real Mac reports 999 cores, so the P/E counts from sysctl can
        // never add up to this — exercises the fallback path without
        // depending on the test machine's actual chip.
        let layout = CPUMonitor.coreTypeLayout(forCoreCount: 999)

        #expect(layout.performanceCount == 0)
        #expect(layout.efficiencyCount == 0)
        #expect(layout.types.count == 999)
        #expect(layout.types.allSatisfy { $0 == .unspecified })
    }

    @Test func matchingCoreCountListsEfficiencyCoresBeforePerformanceCores() {
        // Mirrors CPUMonitor's own fallback logic, so this is only a
        // meaningful check on a Mac that actually reports a P/E split
        // (Apple silicon). On Intel, hw.perflevel1 is absent and both
        // sides agree on "no split" — the assertions below still hold.
        guard
            let performanceCores = Sysctl.int32("hw.perflevel0.physicalcpu").map(Int.init),
            let efficiencyCores = Sysctl.int32("hw.perflevel1.physicalcpu").map(Int.init)
        else {
            let layout = CPUMonitor.coreTypeLayout(forCoreCount: 8)
            #expect(layout.performanceCount == 0)
            #expect(layout.efficiencyCount == 0)
            return
        }

        let coreCount = performanceCores + efficiencyCores
        let layout = CPUMonitor.coreTypeLayout(forCoreCount: coreCount)

        #expect(layout.performanceCount == performanceCores)
        #expect(layout.efficiencyCount == efficiencyCores)
        #expect(layout.types.count == coreCount)

        let efficiencyPrefix = layout.types.prefix(efficiencyCores)
        let performanceSuffix = layout.types.suffix(performanceCores)
        #expect(efficiencyPrefix.allSatisfy { $0 == .efficiency })
        #expect(performanceSuffix.allSatisfy { $0 == .performance })
    }

    @Test func trimmedHistoryDropsSamplesOlderThanTheWindow() {
        let now = Date()
        let samples = [
            CPULoadSample(date: now.addingTimeInterval(-7200), overall: 1, performance: nil, efficiency: nil), // 2h old
            CPULoadSample(date: now.addingTimeInterval(-1800), overall: 2, performance: nil, efficiency: nil), // 30m old
            CPULoadSample(date: now, overall: 3, performance: nil, efficiency: nil), // now
        ]

        let trimmed = CPUMonitor.trimmedHistory(samples, keeping: 3600, relativeTo: now)

        #expect(trimmed.map(\.overall) == [2, 3])
    }

    @Test func trimmedHistoryWindowIsWallClockNotSampleCount() {
        // The window is defined by elapsed time, not by how many samples
        // exist — this must hold regardless of samplingInterval. Ten
        // samples spaced 10 minutes apart span 90 minutes; only the ones
        // within the last 60 minutes (i.e. 0, 10, ..., 60 minutes ago) survive.
        let now = Date()
        let samples = (0..<10).map { i in
            CPULoadSample(date: now.addingTimeInterval(TimeInterval(-i) * 600), overall: Double(i), performance: nil, efficiency: nil)
        }

        let trimmed = CPUMonitor.trimmedHistory(samples, keeping: 3600, relativeTo: now)

        #expect(trimmed.count == 7)
    }
}
