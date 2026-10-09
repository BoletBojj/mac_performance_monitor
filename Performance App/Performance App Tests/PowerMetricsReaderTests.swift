import Foundation
import Testing
@testable import Performance_App

struct PowerMetricsReaderTests {
    /// Trimmed from a real `sudo powermetrics -n 1 -i 1000 -s gpu_power,tasks
    /// --show-process-gpu -f plist` capture taken during development (full
    /// capture also confirmed `gputime_ms_per_s` is absent from every `tasks`
    /// entry on this hardware/OS — see CLAUDE.md). Only the fields this
    /// parser actually reads are kept; the real top-level keys/types
    /// (`elapsed_ns` as `<integer>`, `timestamp` as `<date>`, `gpu.idle_ratio`
    /// as `<real>`, `gpu.gpu_energy` as `<integer>`) are preserved exactly.
    private static let realCaptureFixture = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>is_delta</key><true/>
        <key>elapsed_ns</key><integer>1012295750</integer>
        <key>hw_model</key><string>Mac17,9</string>
        <key>timestamp</key><date>2026-10-09T10:35:00Z</date>
        <key>gpu</key>
        <dict>
        <key>freq_hz</key><real>372.088</real>
        <key>idle_ns</key><integer>868722541</integer>
        <key>idle_ratio</key><real>0.847957</real>
        <key>gpu_energy</key><integer>208</integer>
        </dict>
        </dict>
        </plist>
        """

    @Test func parsesRealCapturedGPUFieldsCorrectly() throws {
        let data = try #require(Self.realCaptureFixture.data(using: .utf8))
        let sample = PowerMetricsReader.parseSample(from: data)

        let sample2 = try #require(sample)
        #expect(abs(sample2.loadFraction - (1 - 0.847957)) < 0.0001)
        // 208 (treated as mJ) / 1.01229575 s ≈ 205.45 mW
        #expect(abs((sample2.milliwatts ?? 0) - 205.45) < 0.5)
    }

    @Test func missingGPUDictReturnsNil() {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            <key>elapsed_ns</key><integer>1000000000</integer>
            </dict>
            </plist>
            """
        let data = plist.data(using: .utf8)!
        #expect(PowerMetricsReader.parseSample(from: data) == nil)
    }

    @Test func missingIdleRatioReturnsNil() {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            <key>elapsed_ns</key><integer>1000000000</integer>
            <key>gpu</key>
            <dict>
            <key>freq_hz</key><real>372.088</real>
            </dict>
            </dict>
            </plist>
            """
        let data = plist.data(using: .utf8)!
        #expect(PowerMetricsReader.parseSample(from: data) == nil)
    }

    @Test func missingEnergyFieldStillReturnsLoadFractionWithNilPower() throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            <key>elapsed_ns</key><integer>1000000000</integer>
            <key>gpu</key>
            <dict>
            <key>idle_ratio</key><real>0.5</real>
            </dict>
            </dict>
            </plist>
            """
        let data = try #require(plist.data(using: .utf8))
        let sample = try #require(PowerMetricsReader.parseSample(from: data))
        #expect(abs(sample.loadFraction - 0.5) < 0.0001)
        #expect(sample.milliwatts == nil)
    }

    @Test func garbageDataReturnsNilInsteadOfCrashing() {
        let garbage = Data([0xFF, 0x00, 0x12, 0x34])
        #expect(PowerMetricsReader.parseSample(from: garbage) == nil)
    }

    @Test func emptyDataReturnsNilInsteadOfCrashing() {
        #expect(PowerMetricsReader.parseSample(from: Data()) == nil)
    }
}
