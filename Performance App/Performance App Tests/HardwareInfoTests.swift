import Testing
@testable import Performance_App

struct HardwareInfoTests {
    @Test func loadReturnsProcessorMemoryAndSystemSections() {
        let sections = HardwareInfo.load()
        let titles = sections.map(\.title)
        #expect(titles == ["Processor", "Memory", "System"])
    }

    @Test func memorySectionAlwaysReportsActiveProcessors() {
        let sections = HardwareInfo.load()
        let memory = sections.first { $0.title == "Memory" }
        #expect(memory?.items.contains { $0.label == "Active Processors" } == true)
    }

    @Test func systemSectionAlwaysReportsMacOSVersionAndHostName() {
        let sections = HardwareInfo.load()
        let system = sections.first { $0.title == "System" }
        #expect(system?.items.contains { $0.label == "macOS Version" } == true)
        #expect(system?.items.contains { $0.label == "Host Name" } == true)
    }
}
