import Foundation
import ServiceManagement

struct ProcessUsageSnapshot: Identifiable {
    let id = UUID()
    let name: String
    let cpuUsage: Double
}

@MainActor
@Observable
final class ProcessHelperClient {
    enum RegistrationStatus: Equatable {
        case notRegistered
        case registered
        case requiresApproval
        case failed(String)
    }

    private(set) var registrationStatus: RegistrationStatus = .notRegistered
    private(set) var topProcesses: [ProcessUsageSnapshot] = []

    private let daemonPlistName = "com.performanceapp.helper.plist"
    private let samplingInterval: TimeInterval = 2
    private var connection: NSXPCConnection?

    /// Runs until the enclosing task is cancelled (e.g. by SwiftUI's `.task`
    /// modifier).
    func start() async {
        registerHelperIfNeeded()
        while !Task.isCancelled {
            fetchTopProcesses()
            try? await Task.sleep(for: .seconds(samplingInterval))
        }
    }

    /// Attempts registration and records exactly what happened — this is the
    /// whole point of this experiment: finding out whether local/free
    /// signing is sufficient for SMAppService, not just whether it works.
    func registerHelperIfNeeded() {
        let service = SMAppService.daemon(plistName: daemonPlistName)

        switch service.status {
        case .enabled:
            registrationStatus = .registered
            return
        case .requiresApproval:
            registrationStatus = .requiresApproval
            return
        default:
            break
        }

        do {
            try service.register()
            registrationStatus = service.status == .enabled ? .registered : .requiresApproval
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    /// BackgroundTaskManagement pins the *exact approved binary* by SHA256
    /// checksum when the daemon is first registered. Rebuilding the helper
    /// changes that checksum, so the already-approved registration starts
    /// refusing to spawn the new binary (`last exit code = 78: EX_CONFIG`)
    /// until it's unregistered and re-registered against the new build.
    /// Needed during development every time the helper's code changes.
    func unregisterHelper() {
        connection?.invalidate()
        connection = nil

        let service = SMAppService.daemon(plistName: daemonPlistName)
        do {
            try service.unregister()
            registrationStatus = .notRegistered
        } catch {
            registrationStatus = .failed("Unregister error: \(error.localizedDescription)")
        }
    }

    func fetchTopProcesses() {
        guard let proxy = currentConnection().remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task { @MainActor in
                self?.registrationStatus = .failed("XPC error: \(error.localizedDescription)")
            }
        }) as? ProcessHelperProtocol else { return }

        proxy.fetchTopProcesses { [weak self] results in
            let parsed = results.compactMap { dict -> ProcessUsageSnapshot? in
                guard let name = dict["name"] as? String, let cpuUsage = dict["cpuUsage"] as? Double else { return nil }
                return ProcessUsageSnapshot(name: name, cpuUsage: cpuUsage)
            }
            Task { @MainActor in
                self?.topProcesses = parsed
            }
        }
    }

    /// `true` once the daemon has been talked to successfully at least once
    /// this session — lets the CPU/Memory views fall back to their own local,
    /// in-memory-only history when the helper isn't available instead of
    /// showing an empty chart.
    private(set) var isHelperReachable = false

    func fetchCPUHistory(since: Date, bucketSeconds: Double) async -> [CPUHistoryPoint] {
        guard let data = await fetchHistoryData({ $0.fetchCPUHistory(since: since, bucketSeconds: bucketSeconds, withReply: $1) }) else { return [] }
        return HistoryCoding.decodeArray(CPUHistoryPoint.self, from: data)
    }

    func fetchMemoryHistory(since: Date, bucketSeconds: Double) async -> [MemoryHistoryPoint] {
        guard let data = await fetchHistoryData({ $0.fetchMemoryHistory(since: since, bucketSeconds: bucketSeconds, withReply: $1) }) else { return [] }
        return HistoryCoding.decodeArray(MemoryHistoryPoint.self, from: data)
    }

    func fetchProcessSummary(since: Date, limit: Int) async -> [ProcessSummaryEntry] {
        guard let data = await fetchHistoryData({ $0.fetchProcessSummary(since: since, limit: limit, withReply: $1) }) else { return [] }
        return HistoryCoding.decodeArray(ProcessSummaryEntry.self, from: data)
    }

    func fetchGPUHistory(since: Date, bucketSeconds: Double) async -> [GPULoadHistoryPoint] {
        guard let data = await fetchHistoryData({ $0.fetchGPUHistory(since: since, bucketSeconds: bucketSeconds, withReply: $1) }) else { return [] }
        return HistoryCoding.decodeArray(GPULoadHistoryPoint.self, from: data)
    }

    func fetchPeaks() async -> [PeakRecord] {
        guard let data = await fetchHistoryData({ $0.fetchPeaks(withReply: $1) }) else { return [] }
        return HistoryCoding.decodeArray(PeakRecord.self, from: data)
    }

    @discardableResult
    func resetPeaks() async -> Bool {
        await withCheckedContinuation { continuation in
            guard let proxy = currentConnection().remoteObjectProxyWithErrorHandler({ _ in
                continuation.resume(returning: false)
            }) as? ProcessHelperProtocol else {
                continuation.resume(returning: false)
                return
            }
            proxy.resetPeaks { success in continuation.resume(returning: success) }
        }
    }

    /// Shared plumbing for the history calls above: get a proxy, invoke the
    /// XPC call, and resolve to `nil` on any connection error instead of
    /// throwing — callers treat "no data" and "helper unreachable" the same
    /// way (fall back to local-only data).
    private func fetchHistoryData(_ call: @escaping (ProcessHelperProtocol, @escaping (Data) -> Void) -> Void) async -> Data? {
        await withCheckedContinuation { continuation in
            guard let proxy = currentConnection().remoteObjectProxyWithErrorHandler({ _ in
                continuation.resume(returning: nil)
            }) as? ProcessHelperProtocol else {
                continuation.resume(returning: nil)
                return
            }
            call(proxy) { [weak self] data in
                Task { @MainActor in self?.isHelperReachable = true }
                continuation.resume(returning: data)
            }
        }
    }

    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }

        let newConnection = NSXPCConnection(machServiceName: processHelperMachServiceName, options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: ProcessHelperProtocol.self)
        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }
}
