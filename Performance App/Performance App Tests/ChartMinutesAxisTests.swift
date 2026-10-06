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

    @Test func tickValuesWithAZeroWindowProducesJustZero() {
        let values = ChartMinutesAxis.tickValues(windowMinutes: 0, strideMinutes: 10)
        #expect(values == [0])
    }

    @Test func tickValuesWithANegativeWindowProduceNoValues() {
        // -windowMinutes becomes positive, which is already past the `through:
        // 0` bound for a positive stride, so the sequence is empty rather than
        // producing nonsensical ticks.
        let values = ChartMinutesAxis.tickValues(windowMinutes: -10, strideMinutes: 10)
        #expect(values.isEmpty)
    }

    @Test func tickLabelFormatsWholeMinutesWithASuffix() {
        #expect(ChartMinutesAxis.tickLabel(forMinutes: -60) == "-60m")
        #expect(ChartMinutesAxis.tickLabel(forMinutes: 0) == "0m")
        #expect(ChartMinutesAxis.tickLabel(forMinutes: -5) == "-5m")
    }

    @Test func tickLabelRoundsFractionalMinutesToTheNearestWhole() {
        // Real call sites only ever pass whole-minute values, but the
        // function's contract is "format a minute value" for any Double, so
        // it must round rather than silently truncate toward zero.
        #expect(ChartMinutesAxis.tickLabel(forMinutes: -2.3) == "-2m")
        #expect(ChartMinutesAxis.tickLabel(forMinutes: -57.5) == "-58m")
    }
}
