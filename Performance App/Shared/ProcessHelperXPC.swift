import Foundation

/// Mach service name shared between the app (client) and the helper
/// daemon (listener). Must match the `MachServices` key in the daemon's
/// launchd plist exactly.
nonisolated let processHelperMachServiceName = "com.performanceapp.helper"

/// NSXPC requires @objc-compatible signatures. Replies are either plain
/// `[String: Any]` dictionaries (String/Double only) or `Data` holding a
/// binary-plist-encoded `Codable` payload (see `HistoryCoding`) — both avoid
/// `NSXPCInterface.setClasses` allow-listing, which is easy to get subtly
/// wrong and hard to verify without two real separate processes.
@objc nonisolated protocol ProcessHelperProtocol {
    /// Latest per-second top processes. Keys: "name" (String), "cpuUsage" (Double).
    func fetchTopProcesses(withReply reply: @escaping ([[String: Any]]) -> Void)

    /// `[CPUHistoryPoint]`, one per `bucketSeconds`-wide bucket since `since`.
    func fetchCPUHistory(since: Date, bucketSeconds: Double, withReply reply: @escaping (Data) -> Void)

    /// `[MemoryHistoryPoint]`, one per `bucketSeconds`-wide bucket since `since`.
    func fetchMemoryHistory(since: Date, bucketSeconds: Double, withReply reply: @escaping (Data) -> Void)

    /// `[ProcessSummaryEntry]`, ranked by average CPU since `since`.
    func fetchProcessSummary(since: Date, limit: Int, withReply reply: @escaping (Data) -> Void)

    /// `[PeakRecord]` — all-time highs, kept across pruning and reboots.
    func fetchPeaks(withReply reply: @escaping (Data) -> Void)

    func resetPeaks(withReply reply: @escaping (Bool) -> Void)
}
