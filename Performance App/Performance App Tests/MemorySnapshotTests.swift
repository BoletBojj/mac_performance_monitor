import Testing
@testable import Performance_App

struct MemorySnapshotTests {
    @Test func usedBytesSumsActiveInactiveWiredAndCompressed() {
        // Deliberately NOT totalBytes - freeBytes: macOS's aggressive disk
        // caching makes raw "free" tiny and misleading, so a naive
        // total-minus-free would overstate usage. Pin the real formula down.
        let snapshot = MemorySnapshot(
            totalBytes: 1000,
            freeBytes: 100,
            activeBytes: 300,
            inactiveBytes: 200,
            wiredBytes: 150,
            compressedBytes: 50,
            swapUsedBytes: 0,
            swapTotalBytes: 0
        )
        #expect(snapshot.usedBytes == 700)
    }

    @Test func usedFractionDividesUsedByTotal() {
        let snapshot = MemorySnapshot(
            totalBytes: 1000,
            freeBytes: 500,
            activeBytes: 500,
            inactiveBytes: 0,
            wiredBytes: 0,
            compressedBytes: 0,
            swapUsedBytes: 0,
            swapTotalBytes: 0
        )
        #expect(snapshot.usedFraction == 0.5)
    }

    @Test func usedFractionWithZeroTotalReturnsZeroInsteadOfDividingByZero() {
        let snapshot = MemorySnapshot(
            totalBytes: 0,
            freeBytes: 0,
            activeBytes: 500,
            inactiveBytes: 0,
            wiredBytes: 0,
            compressedBytes: 0,
            swapUsedBytes: 0,
            swapTotalBytes: 0
        )
        #expect(snapshot.usedFraction == 0)
    }
}
