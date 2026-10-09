import Foundation

nonisolated protocol HistoryDated {
    var date: Date { get }
}

extension CPUHistoryPoint: HistoryDated {}
extension MemoryHistoryPoint: HistoryDated {}
extension GPULoadHistoryPoint: HistoryDated {}

nonisolated enum HistoryGapSegmentation {
    /// Splits a time-ordered series into contiguous runs, breaking wherever
    /// the gap between two consecutive samples exceeds `maxGap` (sleep, or
    /// the helper being unreachable for a while). Chart code draws each run
    /// as its own line segment so a gap reads as a visible break, not a
    /// straight line silently bridging time that was never actually sampled.
    static func segments<T: HistoryDated>(_ points: [T], maxGap: TimeInterval) -> [[T]] {
        guard let first = points.first else { return [] }
        var result: [[T]] = [[first]]
        for point in points.dropFirst() {
            if point.date.timeIntervalSince(result[result.count - 1].last!.date) > maxGap {
                result.append([point])
            } else {
                result[result.count - 1].append(point)
            }
        }
        return result
    }
}
