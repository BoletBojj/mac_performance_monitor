import Testing
@testable import Performance_App

struct ChartTimeAxisTests {
    @Test func strideChoosesFiveMinutesForTheFifteenMinuteRange() {
        #expect(ChartTimeAxis.strideSeconds(forWindowSeconds: HistoryRange.fifteenMinutes.duration) == 5 * 60)
    }

    @Test func strideChoosesTenMinutesForTheOneHourRange() {
        #expect(ChartTimeAxis.strideSeconds(forWindowSeconds: HistoryRange.oneHour.duration) == 10 * 60)
    }

    @Test func strideChoosesOneHourForTheSixHourRange() {
        #expect(ChartTimeAxis.strideSeconds(forWindowSeconds: HistoryRange.sixHours.duration) == 60 * 60)
    }

    @Test func strideChoosesFourHoursForTheTwentyFourHourRange() {
        #expect(ChartTimeAxis.strideSeconds(forWindowSeconds: HistoryRange.twentyFourHours.duration) == 4 * 60 * 60)
    }

    @Test func tickValuesSpanTheFullWindowAtTheGivenStride() {
        let values = ChartTimeAxis.tickValues(windowSeconds: 3600, strideSeconds: 600)
        #expect(values == [-3600, -3000, -2400, -1800, -1200, -600, 0])
    }

    @Test func tickValuesStopBeforeOvershootingWhenStrideDoesNotDivideEvenly() {
        // stride(through:) never produces a value past the upper bound, so a
        // stride that doesn't evenly divide the window simply stops short of 0
        // rather than overshooting it.
        let values = ChartTimeAxis.tickValues(windowSeconds: 1800, strideSeconds: 1200)
        #expect(values == [-1800, -600])
    }

    @Test func tickValuesWithAZeroWindowProducesJustZero() {
        let values = ChartTimeAxis.tickValues(windowSeconds: 0, strideSeconds: 600)
        #expect(values == [0])
    }

    @Test func tickValuesWithANegativeWindowProduceNoValues() {
        // -windowSeconds becomes positive, which is already past the
        // `through: 0` bound for a positive stride, so the sequence is empty
        // rather than producing nonsensical ticks.
        let values = ChartTimeAxis.tickValues(windowSeconds: -600, strideSeconds: 600)
        #expect(values.isEmpty)
    }

    @Test func tickLabelFormatsWholeMinutesWithASuffixUnderAnHour() {
        #expect(ChartTimeAxis.tickLabel(forSecondsAgo: -3540) == "-59m")
        #expect(ChartTimeAxis.tickLabel(forSecondsAgo: 0) == "0m")
        #expect(ChartTimeAxis.tickLabel(forSecondsAgo: -300) == "-5m")
    }

    @Test func tickLabelFormatsWholeHoursAtOrPastAnHour() {
        #expect(ChartTimeAxis.tickLabel(forSecondsAgo: -3600) == "-1h")
        #expect(ChartTimeAxis.tickLabel(forSecondsAgo: -86400) == "-24h")
    }

    @Test func tickLabelRoundsFractionalMinutesToTheNearestWhole() {
        // Real call sites only ever pass whole-minute-aligned values, but the
        // function's contract is "format a seconds-ago value" for any Double,
        // so it must round rather than silently truncate toward zero.
        #expect(ChartTimeAxis.tickLabel(forSecondsAgo: -138) == "-2m")
        #expect(ChartTimeAxis.tickLabel(forSecondsAgo: -3450) == "-58m")
    }
}
