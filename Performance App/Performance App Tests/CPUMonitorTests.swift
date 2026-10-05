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
}
