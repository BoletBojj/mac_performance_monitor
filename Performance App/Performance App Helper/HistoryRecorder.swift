import Foundation
import Darwin

/// Drives the 1 Hz background sampling loop and owns all mutable recording
/// state. Everything runs serialized on `queue`, including the XPC-facing
/// read methods below, since a single `HistoryStore`/SQLite connection isn't
/// safe to use concurrently from multiple threads.
final class HistoryRecorder {
    private let store: HistoryStore
    private let queue = DispatchQueue(label: "com.performanceapp.helper.recorder")
    private var timer: DispatchSourceTimer?

    private var previousTicks: [CPUCoreTicks] = []
    private var layout = CoreTypeLayout(types: [], performanceCount: 0, efficiencyCount: 0)
    private var previousProcessTimes: [pid_t: UInt64] = [:]
    private var lastProcessSampleDate: Date?

    private var cpuBuffer: [HistoryStore.CPUSampleInput] = []
    private var memoryBuffer: [HistoryStore.MemorySampleInput] = []
    private var processBuffer: [HistoryStore.ProcessSampleInput] = []
    private var gpuBuffer: [HistoryStore.GPUSampleInput] = []
    private var tickCount = 0

    /// GPU samples arrive asynchronously from `powermetrics`'s own ~5s
    /// schedule, not from this recorder's 1 Hz tick — see `PowerMetricsReader`.
    private lazy var powerMetricsReader = PowerMetricsReader { [weak self] sample in
        self?.queue.async {
            self?.gpuBuffer.append(HistoryStore.GPUSampleInput(date: sample.date, loadFraction: sample.loadFraction, milliwatts: sample.milliwatts))
        }
    }

    /// Latest ranked list, served directly to `fetchTopProcesses` so the live
    /// view and the recorder share a single process enumeration per second
    /// instead of each client triggering its own `proc_listallpids` sweep.
    private var latestTopProcesses: [[String: Any]] = []

    private let recordedProcessCount = 5 // how many of the ranked list get written to history
    private let liveProcessCount = 15 // how many the live Processes view shows
    private let flushEveryTicks = 10
    private let pruneEveryTicks = 60
    private let retention: TimeInterval = 24 * 60 * 60

    init(store: HistoryStore) {
        self.store = store
    }

    func start() {
        queue.async { [weak self] in self?.pruneNow() }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer

        powerMetricsReader.start()
    }

    // MARK: - Sampling (runs on `queue`)

    private func tick() {
        let now = Date()

        if let ticks = CPUSampling.readTicks() {
            if layout.types.count != ticks.count {
                layout = CPUSampling.coreTypeLayout(forCoreCount: ticks.count)
            }
            if let aggregate = CPUSampling.aggregate(previous: previousTicks, current: ticks, layout: layout) {
                cpuBuffer.append(HistoryStore.CPUSampleInput(
                    date: now, overall: aggregate.overall, performance: aggregate.performance, efficiency: aggregate.efficiency
                ))
            }
            previousTicks = ticks
        }

        if let snapshot = MemorySampling.readSnapshot() {
            memoryBuffer.append(HistoryStore.MemorySampleInput(date: now, snapshot: snapshot))
        }

        sampleProcesses(now: now)

        tickCount += 1
        if tickCount % flushEveryTicks == 0 {
            flushNow()
        }
        if tickCount % pruneEveryTicks == 0 {
            pruneNow()
        }
    }

    private func sampleProcesses(now: Date) {
        let currentTimes = ProcessSampling.sampleProcessTimes()
        defer {
            previousProcessTimes = currentTimes.mapValues(\.totalCPUTime)
            lastProcessSampleDate = now
        }

        guard let lastProcessSampleDate, !currentTimes.isEmpty else { return }
        let elapsed = now.timeIntervalSince(lastProcessSampleDate)

        let ranked = ProcessRanking.topProcesses(
            from: currentTimes, previousTimes: previousProcessTimes, elapsedSeconds: elapsed, limit: liveProcessCount
        )
        latestTopProcesses = ranked.map { ["name": $0.name, "cpuUsage": $0.cpuUsage] }

        let recorded = ranked.prefix(recordedProcessCount).map { (name: $0.name, usage: $0.cpuUsage) }
        if !recorded.isEmpty {
            processBuffer.append(HistoryStore.ProcessSampleInput(date: now, usages: Array(recorded)))
        }
    }

    private func flushNow() {
        guard !(cpuBuffer.isEmpty && memoryBuffer.isEmpty && processBuffer.isEmpty && gpuBuffer.isEmpty) else { return }
        try? store.flush(cpuSamples: cpuBuffer, memorySamples: memoryBuffer, processSamples: processBuffer, gpuSamples: gpuBuffer)
        cpuBuffer.removeAll()
        memoryBuffer.removeAll()
        processBuffer.removeAll()
        gpuBuffer.removeAll()
    }

    /// Cutoff is `max(now - retention, bootTime)`, so a reboot discards
    /// samples from the previous boot immediately, not just samples that
    /// happen to fall outside the 24h window.
    private func pruneNow() {
        let cutoff = max(Date().addingTimeInterval(-retention), SystemClock.bootTime() ?? .distantPast)
        try? store.prune(olderThan: cutoff)
    }

    // MARK: - XPC-facing reads

    func fetchTopProcesses(reply: @escaping ([[String: Any]]) -> Void) {
        queue.async { reply(self.latestTopProcesses) }
    }

    /// Flushes the in-memory buffer before querying, so a history request
    /// always sees up to the most recent sample, not just whatever was
    /// already committed to disk.
    func fetchCPUHistory(since: Date, bucketSeconds: Double, reply: @escaping (Data) -> Void) {
        queue.async {
            self.flushNow()
            let points = (try? self.store.queryCPUHistory(since: since, bucketSeconds: bucketSeconds)) ?? []
            reply(HistoryCoding.encode(points))
        }
    }

    func fetchMemoryHistory(since: Date, bucketSeconds: Double, reply: @escaping (Data) -> Void) {
        queue.async {
            self.flushNow()
            let points = (try? self.store.queryMemoryHistory(since: since, bucketSeconds: bucketSeconds)) ?? []
            reply(HistoryCoding.encode(points))
        }
    }

    func fetchProcessSummary(since: Date, limit: Int, reply: @escaping (Data) -> Void) {
        queue.async {
            self.flushNow()
            let entries = (try? self.store.queryProcessSummary(since: since, limit: limit)) ?? []
            reply(HistoryCoding.encode(entries))
        }
    }

    func fetchGPUHistory(since: Date, bucketSeconds: Double, reply: @escaping (Data) -> Void) {
        queue.async {
            self.flushNow()
            let points = (try? self.store.queryGPUHistory(since: since, bucketSeconds: bucketSeconds)) ?? []
            reply(HistoryCoding.encode(points))
        }
    }

    func fetchPeaks(reply: @escaping (Data) -> Void) {
        queue.async {
            let peaks = (try? self.store.fetchPeaks()) ?? []
            reply(HistoryCoding.encode(peaks))
        }
    }

    func resetPeaks(reply: @escaping (Bool) -> Void) {
        queue.async {
            do {
                try self.store.resetPeaks()
                reply(true)
            } catch {
                reply(false)
            }
        }
    }
}
