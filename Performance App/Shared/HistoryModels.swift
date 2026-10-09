import Foundation

/// Mean/standard-deviation/min/max over a bucket of raw samples. Keeping all
/// four (not just the mean) is what lets a chart still show a brief spike
/// even after many samples have been averaged into one point — the spike
/// barely moves the mean, but it always sets `max`.
nonisolated struct BucketStats: Codable, Equatable {
    let mean: Double
    let stdDev: Double
    let min: Double
    let max: Double
    let count: Int

    /// Population variance = E[x²] − E[x]², computed from running sums so the
    /// database only needs to store/aggregate `SUM(x)` and `SUM(x*x)`, not
    /// every raw sample. Floating-point rounding can push the subtraction
    /// slightly negative for a near-constant series, so it's clamped to zero
    /// before the square root (otherwise `sqrt` of a tiny negative number is NaN).
    init(count: Int, sum: Double, sumOfSquares: Double, min: Double, max: Double) {
        self.count = count
        self.min = min
        self.max = max
        guard count > 0 else {
            self.mean = 0
            self.stdDev = 0
            return
        }
        let mean = sum / Double(count)
        let variance = Swift.max(0, sumOfSquares / Double(count) - mean * mean)
        self.mean = mean
        self.stdDev = variance.squareRoot()
    }

    /// Mean ± 1 standard deviation, clamped to [min, max] so the band never
    /// implies load that didn't happen within the bucket.
    var lowerBand: Double { Swift.max(min, mean - stdDev) }
    var upperBand: Double { Swift.min(max, mean + stdDev) }
}

nonisolated struct CPUHistoryPoint: Codable, Equatable, Identifiable {
    let date: Date
    let overall: BucketStats
    let performance: BucketStats?
    let efficiency: BucketStats?

    var id: Date { date }
}

nonisolated struct MemoryHistoryPoint: Codable, Equatable, Identifiable {
    let date: Date
    let active: Double
    let inactive: Double
    let wired: Double
    let compressed: Double
    let used: BucketStats // the stack uses the per-category means; `used` carries the spread

    var id: Date { date }
}

/// One `powermetrics` sample. Unlike every other sampled value in this app,
/// this doesn't come from a direct Mach/BSD syscall — see `PowerMetricsReader`
/// for why, and why its fields are optional/defensive.
nonisolated struct GPULoadSample: Codable, Equatable {
    let date: Date
    let loadFraction: Double // 0...1, derived as 1 - idle_ratio
    let milliwatts: Double? // derived from an energy-per-sample field; less certain than loadFraction
}

nonisolated struct GPULoadHistoryPoint: Codable, Equatable, Identifiable {
    let date: Date
    let load: BucketStats
    let power: BucketStats?

    var id: Date { date }
}

nonisolated struct ProcessSummaryEntry: Codable, Equatable, Identifiable {
    let name: String
    let averageUsage: Double
    let peakUsage: Double
    let peakDate: Date

    var id: String { name }
}

nonisolated struct PeakRecord: Codable, Equatable, Identifiable {
    enum Metric: String, Codable, CaseIterable {
        case cpuTotal = "cpu.total"
        case cpuPerformance = "cpu.performance"
        case cpuEfficiency = "cpu.efficiency"
        case memoryUsed = "memory.used"
        case singleProcess = "process.single"
        case gpuLoad = "gpu.load"
    }

    let metric: Metric
    let value: Double
    let date: Date
    let detail: String? // process name, for .singleProcess

    var id: Metric { metric }
}

/// A selectable chart window. `duration` is the requested span; the actual
/// start is clamped to boot time by the caller, since there's no history
/// before that regardless of the retention window.
nonisolated enum HistoryRange: CaseIterable, Identifiable {
    case fifteenMinutes
    case oneHour
    case sixHours
    case twentyFourHours

    var id: Self { self }

    var label: String {
        switch self {
        case .fifteenMinutes: "15m"
        case .oneHour: "1h"
        case .sixHours: "6h"
        case .twentyFourHours: "24h"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        case .sixHours: 6 * 60 * 60
        case .twentyFourHours: 24 * 60 * 60
        }
    }

    /// Targets roughly 720 points across the full range, so the chart stays
    /// responsive regardless of how much raw data exists. At the shortest
    /// range this is sub-second, which the store floors to at least 1s (the
    /// raw sampling rate), so 15m effectively shows every raw sample.
    var bucketSeconds: Double {
        max(1, duration / 720)
    }

    /// The effective query start: `duration` ago, but never before boot —
    /// there's no meaningful history before that regardless of retention.
    func effectiveStart(now: Date, bootTime: Date?) -> Date {
        let requestedStart = now.addingTimeInterval(-duration)
        guard let bootTime else { return requestedStart }
        return max(requestedStart, bootTime)
    }

    /// Re-fetch cadence while this range is on screen — short ranges refresh
    /// close to the live sampling rate, long ranges less often since a single
    /// bucket already spans minutes.
    var refreshInterval: TimeInterval {
        switch self {
        case .fifteenMinutes: 1
        case .oneHour, .sixHours, .twentyFourHours: 5
        }
    }
}
