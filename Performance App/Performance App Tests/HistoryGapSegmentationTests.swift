import Foundation
import Testing
@testable import Performance_App

struct HistoryGapSegmentationTests {
    private func point(_ secondsFromNow: TimeInterval, base: Date) -> CPUHistoryPoint {
        let value = BucketStats(count: 1, sum: 1, sumOfSquares: 1, min: 1, max: 1)
        return CPUHistoryPoint(date: base.addingTimeInterval(secondsFromNow), overall: value, performance: nil, efficiency: nil)
    }

    @Test func emptyInputProducesNoSegments() {
        #expect(HistoryGapSegmentation.segments([CPUHistoryPoint](), maxGap: 10).isEmpty)
    }

    @Test func evenlySpacedPointsStayInOneSegment() {
        let base = Date()
        let points = (0..<5).map { point(TimeInterval($0) * 5, base: base) }
        let segments = HistoryGapSegmentation.segments(points, maxGap: 10)
        #expect(segments.count == 1)
        #expect(segments[0].count == 5)
    }

    @Test func aGapLargerThanMaxGapStartsANewSegment() {
        let base = Date()
        let points = [point(0, base: base), point(5, base: base), point(500, base: base), point(505, base: base)]
        let segments = HistoryGapSegmentation.segments(points, maxGap: 10)
        #expect(segments.count == 2)
        #expect(segments[0].count == 2)
        #expect(segments[1].count == 2)
    }

    @Test func aGapExactlyAtMaxGapDoesNotSplit() {
        // Boundary: the comparison is strictly `>`, so a gap exactly equal to
        // maxGap is still treated as one continuous segment.
        let base = Date()
        let points = [point(0, base: base), point(10, base: base)]
        let segments = HistoryGapSegmentation.segments(points, maxGap: 10)
        #expect(segments.count == 1)
    }

    @Test func multipleGapsProduceMultipleSegments() {
        let base = Date()
        let points = [
            point(0, base: base),
            point(100, base: base),
            point(200, base: base),
        ]
        let segments = HistoryGapSegmentation.segments(points, maxGap: 50)
        #expect(segments.count == 3)
        #expect(segments.allSatisfy { $0.count == 1 })
    }
}
