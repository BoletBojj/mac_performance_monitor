import Testing
@testable import Performance_App

struct GPUInfoTests {
    @Test func loadReturnsAtLeastOneGPUSection() {
        // Every Mac that can run this app has at least one Metal device.
        let sections = GPUInfo.load()
        #expect(!sections.isEmpty)
    }

    @Test func firstGPUSectionReportsNameAndMetal3Support() {
        let sections = GPUInfo.load()
        let items = sections.first?.items ?? []
        #expect(items.contains { $0.label == "Name" && !$0.value.isEmpty })
        #expect(items.contains { $0.label == "Metal 3 Support" })
    }
}
