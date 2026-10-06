import Testing
@testable import Performance_App

struct SysctlTests {
    @Test func stringReadsAKnownKey() {
        // hw.model exists on every Mac (e.g. "Mac15,6", "MacBookPro18,1").
        let model = Sysctl.string("hw.model")
        #expect(model != nil)
        #expect(model?.isEmpty == false)
    }

    @Test func stringReturnsNilForUnknownKey() {
        #expect(Sysctl.string("hw.this_key_does_not_exist") == nil)
    }

    @Test func int32ReadsPhysicalCoreCount() {
        let physicalCores = Sysctl.int32("hw.physicalcpu")
        #expect(physicalCores != nil)
        #expect((physicalCores ?? 0) > 0)
    }

    @Test func uint64ReadsPhysicalMemorySize() {
        let memSize = Sysctl.uint64("hw.memsize")
        #expect(memSize != nil)
        #expect((memSize ?? 0) > 0)
    }

    @Test func stringReturnsNilForAnEmptyKey() {
        #expect(Sysctl.string("") == nil)
    }

    @Test func int32ReturnsNilForATypeMismatchedKey() {
        // hw.model is a string sysctl; reading it as a fixed 4-byte int32
        // buffer should fail (ENOMEM) and return nil rather than garbage.
        #expect(Sysctl.int32("hw.model") == nil)
    }

    @Test func uint64ReturnsNilForAnUnknownKey() {
        #expect(Sysctl.uint64("hw.this_key_does_not_exist") == nil)
    }
}
