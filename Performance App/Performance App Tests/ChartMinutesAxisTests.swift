import Testing
@testable import Performance_App

struct ChartMinutesAxisTests {
    @Test func tickValuesSpanTheFullWindowAtTheGivenStride() {
        let values = ChartMinutesAxis.tickValues(windowMinutes: 60, strideMinutes: 10)
        #expect(values == [-60, -50, -40, -30, -20, -10, 0])
    }

    @Test func tickValuesStopBeforeOvershootingWhenStrideDoesNotDivideEvenly() {
        // stride(through:) never produces a value past the upper bound, so a
        // stride that doesn't evenly divide the window simply stops short of 0
        // rather than overshooting it.
        let values = ChartMinutesAxis.tickValues(windowMinutes: 30, strideMinutes: 20)
        #expect(values == [-30, -10])
    }

    @Test func tickLabelFormatsWholeMinutesWithASuffix() {
        #expect(ChartMinutesAxis.tickLabel(forMinutes: -60) == "-60m")
        #expect(ChartMinutesAxis.tickLabel(forMinutes: 0) == "0m")
        #expect(ChartMinutesAxis.tickLabel(forMinutes: -5) == "-5m")
    }
}
