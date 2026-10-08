import Testing
@testable import Performance_App

struct BucketStatsTests {
    @Test func computesMeanAndStdDevFromKnownSamples() {
        // Samples: 2, 4, 4, 4, 5, 5, 7, 9 -> mean 5, population stdDev 2.
        let values: [Double] = [2, 4, 4, 4, 5, 5, 7, 9]
        let sum = values.reduce(0, +)
        let sumOfSquares = values.reduce(0) { $0 + $1 * $1 }

        let stats = BucketStats(count: values.count, sum: sum, sumOfSquares: sumOfSquares, min: values.min()!, max: values.max()!)

        #expect(stats.mean == 5)
        #expect(stats.stdDev == 2)
        #expect(stats.min == 2)
        #expect(stats.max == 9)
    }

    @Test func constantSeriesHasZeroStdDev() {
        let stats = BucketStats(count: 5, sum: 50, sumOfSquares: 500, min: 10, max: 10)
        #expect(stats.mean == 10)
        #expect(stats.stdDev == 0)
    }

    @Test func singleSampleHasZeroStdDev() {
        let stats = BucketStats(count: 1, sum: 42, sumOfSquares: 42 * 42, min: 42, max: 42)
        #expect(stats.mean == 42)
        #expect(stats.stdDev == 0)
    }

    @Test func zeroCountDoesNotDivideByZero() {
        let stats = BucketStats(count: 0, sum: 0, sumOfSquares: 0, min: 0, max: 0)
        #expect(stats.mean == 0)
        #expect(stats.stdDev == 0)
    }

    @Test func floatingPointRoundingNegativeVarianceClampsToZeroNotNaN() {
        // A near-constant series where sumOfSquares/count - mean*mean can land
        // just below zero due to floating-point rounding, not because the
        // true variance is negative (which is mathematically impossible).
        let mean = 1_000_000.0
        let sum = mean * 3
        let sumOfSquares = sum * mean - 1e-6 // deliberately nudged slightly low
        let stats = BucketStats(count: 3, sum: sum, sumOfSquares: sumOfSquares, min: mean, max: mean)
        #expect(stats.stdDev == 0)
        #expect(!stats.stdDev.isNaN)
    }

    @Test func bandsAreClampedToMinAndMax() {
        // mean=5, stdDev=10 would put mean-stdDev below min and mean+stdDev
        // above max if unclamped — the bands must never imply load that
        // didn't happen within the bucket.
        let stats = BucketStats(count: 2, sum: 10, sumOfSquares: 500, min: 4, max: 6)
        #expect(stats.lowerBand >= stats.min)
        #expect(stats.upperBand <= stats.max)
    }
}
