import Foundation

/// Launches `powermetrics` as a long-running subprocess and parses its
/// continuous, NUL-separated plist output stream. Lives in `Shared/` (rather
/// than the Helper target, where it's actually used) purely so its pure
/// parsing function is reachable from tests via `@testable import
/// Performance_App` — the same reasoning as `ProcessRanking`.
///
/// Unlike every other sampled value in this app (`host_processor_info`,
/// `host_statistics64`, `proc_pid_rusage` — all direct Mach/BSD syscalls
/// polled on our own timer), `powermetrics` isn't something you poll: it's a
/// separate process that samples on its own schedule and streams results.
/// That means this reader owns a subprocess lifecycle (launch, read
/// incrementally, restart if it dies) instead of just calling a function —
/// see ARCHITECTURE.md for the general shape.
///
/// `powermetrics`'s plist output isn't part of any Apple-published schema.
/// The fields used here (`gpu.idle_ratio`, `gpu.gpu_energy`, `elapsed_ns`,
/// `timestamp`) were confirmed by directly capturing and inspecting real
/// output during development, not from documentation — treat every field as
/// optional and skip a sample rather than crash if the shape ever changes.
/// Per-process GPU time (`--show-process-gpu`'s `gputime_ms_per_s`) was
/// investigated the same way and found to be absent entirely on this
/// hardware/OS, which is why there's no per-process GPU support here at all.
final class PowerMetricsReader {
    private let queue = DispatchQueue(label: "com.performanceapp.helper.powermetrics")
    private let onSample: (GPULoadSample) -> Void
    private var process: Process?
    private var outputPipe: Pipe?
    private var buffer = Data()

    init(onSample: @escaping (GPULoadSample) -> Void) {
        self.onSample = onSample
    }

    func start() {
        queue.async { [weak self] in self?.launch() }
    }

    private func launch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = ["-s", "gpu_power", "-i", "5000", "-f", "plist"]
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.ingest(data) }
        }

        // powermetrics should run for the helper's whole lifetime; if it
        // ever exits (crash, killed, etc.), relaunch it rather than silently
        // losing GPU data for the rest of the session.
        process.terminationHandler = { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 2) { self?.launch() }
        }

        self.process = process
        outputPipe = pipe
        buffer.removeAll()

        do {
            try process.run()
        } catch {
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.launch() }
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let nulIndex = buffer.firstIndex(of: 0) {
            let chunk = Data(buffer[buffer.startIndex..<nulIndex])
            buffer.removeSubrange(buffer.startIndex...nulIndex)
            if let sample = Self.parseSample(from: chunk) {
                onSample(sample)
            }
        }
    }

    /// Pulled out as a pure function so it's testable against a real captured
    /// `powermetrics -s gpu_power -f plist` fixture without needing the
    /// subprocess itself — the same "narrow testable seam" pattern used
    /// throughout this project for logic that would otherwise be tangled up
    /// with live system/process state.
    static func parseSample(from data: Data) -> GPULoadSample? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let gpu = plist["gpu"] as? [String: Any],
            let idleRatio = number(gpu["idle_ratio"])
        else { return nil }

        let date = plist["timestamp"] as? Date ?? Date()
        let loadFraction = 1 - idleRatio

        var milliwatts: Double?
        if let gpuEnergy = number(gpu["gpu_energy"]), let elapsedNs = number(plist["elapsed_ns"]), elapsedNs > 0 {
            // gpu_energy is an energy delta for the sample window (treated as
            // millijoules, the standard community convention for powermetrics'
            // *_energy fields — not Apple-documented). mJ / s = mW.
            milliwatts = gpuEnergy / (elapsedNs / 1_000_000_000)
        }

        return GPULoadSample(date: date, loadFraction: loadFraction, milliwatts: milliwatts)
    }

    /// `PropertyListSerialization` can hand back plist numbers as `Double`,
    /// `Int`, or `NSNumber` depending on the underlying type — read
    /// defensively rather than assume one.
    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}
