import Testing
@testable import Performance_App

struct CPUCoreTypeTests {
    @Test func performanceLabelIncludesIndex() {
        #expect(CPUCoreType.performance.label(index: 3) == "Performance Core 3")
    }

    @Test func efficiencyLabelIncludesIndex() {
        #expect(CPUCoreType.efficiency.label(index: 0) == "Efficiency Core 0")
    }

    @Test func unspecifiedLabelFallsBackToPlainCore() {
        #expect(CPUCoreType.unspecified.label(index: 5) == "Core 5")
    }

    @Test func labelHandlesANegativeIndexWithoutCrashing() {
        // label(index:) is pure string formatting with no documented
        // precondition on index — a negative value should format, not trap.
        #expect(CPUCoreType.performance.label(index: -1) == "Performance Core -1")
    }

    @Test func performanceAndEfficiencyHaveExplanations() {
        #expect(CPUCoreType.performance.explanation != nil)
        #expect(CPUCoreType.efficiency.explanation != nil)
    }

    @Test func unspecifiedHasNoExplanation() {
        #expect(CPUCoreType.unspecified.explanation == nil)
    }
}
