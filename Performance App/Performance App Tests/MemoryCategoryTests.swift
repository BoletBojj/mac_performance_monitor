import Testing
@testable import Performance_App

struct MemoryCategoryTests {
    @Test func labelsMatchExpectedText() {
        #expect(MemoryCategory.active.label == "Active")
        #expect(MemoryCategory.inactive.label == "Inactive")
        #expect(MemoryCategory.wired.label == "Wired")
        #expect(MemoryCategory.compressed.label == "Compressed")
        #expect(MemoryCategory.free.label == "Free")
    }

    @Test func everyCategoryHasAnExplanation() {
        for category in MemoryCategory.allCases {
            #expect(!category.explanation.isEmpty)
        }
    }

    @Test func bytesReadsTheMatchingSnapshotField() {
        let snapshot = MemorySnapshot(
            totalBytes: 1000,
            freeBytes: 10,
            activeBytes: 20,
            inactiveBytes: 30,
            wiredBytes: 40,
            compressedBytes: 50,
            swapUsedBytes: 0,
            swapTotalBytes: 0
        )

        #expect(MemoryCategory.active.bytes(in: snapshot) == 20)
        #expect(MemoryCategory.inactive.bytes(in: snapshot) == 30)
        #expect(MemoryCategory.wired.bytes(in: snapshot) == 40)
        #expect(MemoryCategory.compressed.bytes(in: snapshot) == 50)
        #expect(MemoryCategory.free.bytes(in: snapshot) == 10)
    }
}
