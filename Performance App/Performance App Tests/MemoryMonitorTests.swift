import Foundation
import Testing
@testable import Performance_App

struct MemoryMonitorTests {
    private func sample(_ date: Date) -> MemorySample {
        MemorySample(date: date, snapshot: MemorySnapshot(
            totalBytes: 100, freeBytes: 0, activeBytes: 100, inactiveBytes: 0,
            wiredBytes: 0, compressedBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0
        ))
    }

    @Test func trimmedHistoryDropsSamplesOlderThanTheWindow() {
        let now = Date()
        let samples = [
            sample(now.addingTimeInterval(-7200)), // 2h old
            sample(now.addingTimeInterval(-1800)), // 30m old
            sample(now), // now
        ]

        let trimmed = MemoryMonitor.trimmedHistory(samples, keeping: 3600, relativeTo: now)

        #expect(trimmed.map(\.date) == [samples[1].date, samples[2].date])
    }

    @Test func trimmedHistoryWindowIsWallClockNotSampleCount() {
        // Ten samples spaced 10 minutes apart span 90 minutes; only the ones
        // within the last 60 minutes survive, regardless of sampling cadence.
        let now = Date()
        let samples = (0..<10).map { i in sample(now.addingTimeInterval(TimeInterval(-i) * 600)) }

        let trimmed = MemoryMonitor.trimmedHistory(samples, keeping: 3600, relativeTo: now)

        #expect(trimmed.count == 7)
    }

    @Test func trimmedHistoryOnEmptyInputStaysEmpty() {
        let trimmed = MemoryMonitor.trimmedHistory([], keeping: 3600, relativeTo: Date())
        #expect(trimmed.isEmpty)
    }

    @Test func trimmedHistoryBoundaryIsInclusive() {
        // A sample exactly `window` seconds old should be kept, not dropped.
        let now = Date()
        let samples = [sample(now.addingTimeInterval(-3600))]

        let trimmed = MemoryMonitor.trimmedHistory(samples, keeping: 3600, relativeTo: now)

        #expect(trimmed.count == 1)
    }

    @Test func trimmedHistoryWithNonPositiveWindowKeepsNothingFromThePast() {
        let now = Date()
        let samples = [sample(now.addingTimeInterval(-1)), sample(now)]

        #expect(MemoryMonitor.trimmedHistory(samples, keeping: 0, relativeTo: now).map(\.date) == [samples[1].date])
        #expect(MemoryMonitor.trimmedHistory(samples, keeping: -10, relativeTo: now).isEmpty)
    }
}
