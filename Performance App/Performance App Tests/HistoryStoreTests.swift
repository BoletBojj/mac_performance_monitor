import Foundation
import Testing
@testable import Performance_App

struct HistoryStoreTests {
    private func makeStore() throws -> HistoryStore {
        let path = NSTemporaryDirectory() + "history-store-test-\(UUID().uuidString).sqlite"
        return try HistoryStore(path: path)
    }

    @Test func insertAndQueryCPUHistoryRoundTrip() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_000_000)
        let samples = (0..<5).map { i in
            HistoryStore.CPUSampleInput(date: base.addingTimeInterval(TimeInterval(i)), overall: Double(i) * 0.1, performance: nil, efficiency: nil)
        }
        try store.flush(cpuSamples: samples, memorySamples: [], processSamples: [])

        let points = try store.queryCPUHistory(since: base.addingTimeInterval(-10), bucketSeconds: 100)
        #expect(points.count == 1)
        let stats = try #require(points.first).overall
        #expect(stats.count == 5)
        #expect(abs(stats.mean - 0.2) < 0.0001) // mean of 0, 0.1, 0.2, 0.3, 0.4
        #expect(stats.min == 0)
        #expect(abs(stats.max - 0.4) < 0.0001)
    }

    @Test func insertAndQueryGPUHistoryRoundTrip() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_500_000)
        let samples = [
            HistoryStore.GPUSampleInput(date: base, loadFraction: 0.1, milliwatts: 200),
            HistoryStore.GPUSampleInput(date: base.addingTimeInterval(1), loadFraction: 0.3, milliwatts: 400),
        ]
        try store.flush(cpuSamples: [], memorySamples: [], processSamples: [], gpuSamples: samples)

        let points = try store.queryGPUHistory(since: base.addingTimeInterval(-1), bucketSeconds: 100)
        let point = try #require(points.first)
        #expect(abs(point.load.mean - 0.2) < 0.0001)
        #expect(point.load.min == 0.1)
        #expect(point.load.max == 0.3)
        let power = try #require(point.power)
        #expect(abs(power.mean - 300) < 0.0001)
    }

    @Test func gpuHistoryOmitsPowerWhenNeverRecorded() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_600_000)
        try store.flush(
            cpuSamples: [], memorySamples: [], processSamples: [],
            gpuSamples: [HistoryStore.GPUSampleInput(date: base, loadFraction: 0.2, milliwatts: nil)]
        )
        let points = try store.queryGPUHistory(since: base.addingTimeInterval(-1), bucketSeconds: 100)
        #expect(points.first?.power == nil)
    }

    @Test func gpuLoadPeakSurvivesPruning() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000)
        try store.flush(
            cpuSamples: [], memorySamples: [], processSamples: [],
            gpuSamples: [HistoryStore.GPUSampleInput(date: base, loadFraction: 0.9, milliwatts: 500)]
        )
        try store.prune(olderThan: base.addingTimeInterval(1000))
        let peaks = try store.fetchPeaks()
        #expect(peaks.first { $0.metric == .gpuLoad }?.value == 0.9)
    }

    @Test func cpuHistoryOmitsPerformanceEfficiencyWhenNeverRecorded() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 2_000_000)
        try store.flush(
            cpuSamples: [HistoryStore.CPUSampleInput(date: base, overall: 1, performance: nil, efficiency: nil)],
            memorySamples: [], processSamples: []
        )
        let points = try store.queryCPUHistory(since: base.addingTimeInterval(-1), bucketSeconds: 10)
        #expect(points.first?.performance == nil)
        #expect(points.first?.efficiency == nil)
    }

    @Test func insertAndQueryMemoryHistoryRoundTrip() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 3_000_000)
        let snapshot = MemorySnapshot(
            totalBytes: 1000, freeBytes: 100, activeBytes: 400, inactiveBytes: 200,
            wiredBytes: 200, compressedBytes: 100, swapUsedBytes: 0, swapTotalBytes: 0
        )
        try store.flush(
            cpuSamples: [],
            memorySamples: [HistoryStore.MemorySampleInput(date: base, snapshot: snapshot)],
            processSamples: []
        )
        let points = try store.queryMemoryHistory(since: base.addingTimeInterval(-1), bucketSeconds: 10)
        let point = try #require(points.first)
        #expect(point.active == 400)
        #expect(point.inactive == 200)
        #expect(point.wired == 200)
        #expect(point.compressed == 100)
        #expect(point.used.mean == 900) // active+inactive+wired+compressed, not total-free
    }

    @Test func pruneRemovesOldSamplesButKeepsRecent() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 4_000_000)
        try store.flush(
            cpuSamples: [
                HistoryStore.CPUSampleInput(date: base, overall: 1, performance: nil, efficiency: nil),
                HistoryStore.CPUSampleInput(date: base.addingTimeInterval(100), overall: 2, performance: nil, efficiency: nil),
            ],
            memorySamples: [], processSamples: []
        )
        try store.prune(olderThan: base.addingTimeInterval(50))

        let points = try store.queryCPUHistory(since: base.addingTimeInterval(-10), bucketSeconds: 1000)
        #expect(points.first?.overall.count == 1)
        #expect(points.first?.overall.mean == 2)
    }

    @Test func processSummaryRanksByAverageAndTracksPeak() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 5_000_000)
        try store.flush(
            cpuSamples: [],
            memorySamples: [],
            processSamples: [
                HistoryStore.ProcessSampleInput(date: base, usages: [(name: "Busy", usage: 0.8), (name: "Quiet", usage: 0.1)]),
                HistoryStore.ProcessSampleInput(date: base.addingTimeInterval(1), usages: [(name: "Busy", usage: 0.4), (name: "Quiet", usage: 0.1)]),
            ]
        )
        let summary = try store.queryProcessSummary(since: base.addingTimeInterval(-1), limit: 10)
        #expect(summary.map(\.name) == ["Busy", "Quiet"]) // ranked by average, descending
        let busy = try #require(summary.first { $0.name == "Busy" })
        #expect(abs(busy.averageUsage - 0.6) < 0.0001)
        #expect(busy.peakUsage == 0.8)
    }

    @Test func processSummaryRespectsLimit() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 6_000_000)
        let usages = (0..<5).map { (name: "P\($0)", usage: Double($0)) }
        try store.flush(cpuSamples: [], memorySamples: [], processSamples: [HistoryStore.ProcessSampleInput(date: base, usages: usages)])
        let summary = try store.queryProcessSummary(since: base.addingTimeInterval(-1), limit: 2)
        #expect(summary.count == 2)
    }

    @Test func peaksOnlyIncreaseAndSurvivePruning() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 7_000_000)
        try store.flush(
            cpuSamples: [HistoryStore.CPUSampleInput(date: base, overall: 5, performance: nil, efficiency: nil)],
            memorySamples: [], processSamples: []
        )
        try store.flush(
            cpuSamples: [HistoryStore.CPUSampleInput(date: base.addingTimeInterval(1), overall: 2, performance: nil, efficiency: nil)],
            memorySamples: [], processSamples: []
        )
        var peaks = try store.fetchPeaks()
        #expect(peaks.first { $0.metric == .cpuTotal }?.value == 5) // lower second sample doesn't overwrite the peak

        // Pruning everything must not touch the peaks table.
        try store.prune(olderThan: base.addingTimeInterval(1000))
        peaks = try store.fetchPeaks()
        #expect(peaks.first { $0.metric == .cpuTotal }?.value == 5)
    }

    @Test func resetPeaksClearsRecords() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 8_000_000)
        try store.flush(
            cpuSamples: [HistoryStore.CPUSampleInput(date: base, overall: 5, performance: nil, efficiency: nil)],
            memorySamples: [], processSamples: []
        )
        try store.resetPeaks()
        #expect(try store.fetchPeaks().isEmpty)
    }
}
