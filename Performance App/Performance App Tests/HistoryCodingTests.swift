import Foundation
import Testing
@testable import Performance_App

struct HistoryCodingTests {
    @Test func encodesAndDecodesCPUHistoryPointsRoundTrip() {
        let stats = BucketStats(count: 3, sum: 6, sumOfSquares: 14, min: 1, max: 3)
        let points = [
            CPUHistoryPoint(date: Date(timeIntervalSince1970: 1000), overall: stats, performance: stats, efficiency: nil),
            CPUHistoryPoint(date: Date(timeIntervalSince1970: 2000), overall: stats, performance: nil, efficiency: nil),
        ]

        let data = HistoryCoding.encode(points)
        let decoded = HistoryCoding.decodeArray(CPUHistoryPoint.self, from: data)

        #expect(decoded == points)
    }

    @Test func encodesAndDecodesPeakRecordsRoundTrip() {
        let peaks = [
            PeakRecord(metric: .cpuTotal, value: 4.5, date: Date(timeIntervalSince1970: 500), detail: nil),
            PeakRecord(metric: .singleProcess, value: 0.9, date: Date(timeIntervalSince1970: 600), detail: "Xcode"),
        ]

        let data = HistoryCoding.encode(peaks)
        let decoded = HistoryCoding.decodeArray(PeakRecord.self, from: data)

        #expect(decoded == peaks)
    }

    @Test func decodingEmptyDataReturnsEmptyArrayInsteadOfCrashing() {
        let decoded = HistoryCoding.decodeArray(PeakRecord.self, from: Data())
        #expect(decoded.isEmpty)
    }

    @Test func decodingGarbageDataReturnsEmptyArrayInsteadOfCrashing() {
        let garbage = Data([0xFF, 0x00, 0x12, 0x34, 0xAB])
        let decoded = HistoryCoding.decodeArray(CPUHistoryPoint.self, from: garbage)
        #expect(decoded.isEmpty)
    }

    @Test func encodingProducesBinaryPlistFormat() {
        // Not load-bearing for correctness, but documents the intentional
        // choice (binary, not XML) — a format regression here would still
        // round-trip correctly above but silently bloat every XPC reply.
        let data = HistoryCoding.encode([PeakRecord(metric: .cpuTotal, value: 1, date: Date(), detail: nil)])
        #expect(data.starts(with: "bplist".utf8))
    }
}
