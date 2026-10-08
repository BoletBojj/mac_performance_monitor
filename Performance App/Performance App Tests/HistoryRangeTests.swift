import Foundation
import Testing
@testable import Performance_App

struct HistoryRangeTests {
    @Test func bucketSecondsTargetsAboutSevenHundredTwentyPointsPerRange() {
        for range in HistoryRange.allCases {
            let bucketCount = range.duration / range.bucketSeconds
            #expect(bucketCount <= 720)
            #expect(bucketCount >= 700) // allow for the 1s floor below
        }
    }

    @Test func bucketSecondsNeverGoesBelowOneSecond() {
        // The raw sampling rate is 1Hz, so a sub-second bucket would be
        // meaningless — the 15m range's natural bucket (15*60/720 = 1.25s)
        // is the smallest in practice, well above the floor, but the floor
        // itself must still hold for any future, shorter range.
        for range in HistoryRange.allCases {
            #expect(range.bucketSeconds >= 1)
        }
    }

    @Test func effectiveStartUsesRequestedDurationWhenBootIsOlder() {
        let now = Date()
        let bootTime = now.addingTimeInterval(-10 * 24 * 60 * 60) // booted 10 days ago
        let start = HistoryRange.oneHour.effectiveStart(now: now, bootTime: bootTime)
        #expect(abs(start.timeIntervalSince(now.addingTimeInterval(-HistoryRange.oneHour.duration))) < 0.001)
    }

    @Test func effectiveStartClampsToBootTimeWhenBootIsMoreRecentThanTheRange() {
        let now = Date()
        let bootTime = now.addingTimeInterval(-60) // booted 1 minute ago
        let start = HistoryRange.twentyFourHours.effectiveStart(now: now, bootTime: bootTime)
        #expect(start == bootTime)
    }

    @Test func effectiveStartWithNoKnownBootTimeUsesRequestedDuration() {
        let now = Date()
        let start = HistoryRange.sixHours.effectiveStart(now: now, bootTime: nil)
        #expect(abs(start.timeIntervalSince(now.addingTimeInterval(-HistoryRange.sixHours.duration))) < 0.001)
    }
}
