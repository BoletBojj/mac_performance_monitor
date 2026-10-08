import Foundation

/// The four kernel-tracked categories that make up `usedBytes`. No `Color`
/// here deliberately — this is model/domain data; the view layer decides how
/// to present each category (color, iconography).
enum MemoryCategory: CaseIterable, Hashable {
    case active, inactive, wired, compressed, free

    var label: String {
        switch self {
        case .active: "Active"
        case .inactive: "Inactive"
        case .wired: "Wired"
        case .compressed: "Compressed"
        case .free: "Free"
        }
    }

    var explanation: String {
        switch self {
        case .active:
            "Memory actively in use by running apps right now — the most recently and frequently accessed pages."
        case .inactive:
            "Memory from apps or data you're not using right now, like a recently-closed app. macOS keeps it around so reopening is fast, but reclaims it immediately if something else needs the space."
        case .wired:
            "Memory that can never be compressed or paged out to disk — used by the kernel and device drivers for data that must always stay in RAM."
        case .compressed:
            "Memory macOS has compressed in place to free up space, trading a bit of CPU time for extra usable RAM instead of writing it to disk."
        case .free:
            "Memory not currently allocated to anything. macOS deliberately keeps this low — it would rather cache recently-used data (Inactive) than leave RAM sitting idle."
        }
    }

    func bytes(in snapshot: MemorySnapshot) -> UInt64 {
        switch self {
        case .active: snapshot.activeBytes
        case .inactive: snapshot.inactiveBytes
        case .wired: snapshot.wiredBytes
        case .compressed: snapshot.compressedBytes
        case .free: snapshot.freeBytes
        }
    }
}

/// One point in the app's local (fallback) memory-over-time chart — mirrors
/// `CPULoadSample`'s role for `CPUMonitor`.
struct MemorySample: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let snapshot: MemorySnapshot
}

@MainActor
@Observable
final class MemoryMonitor {
    private(set) var snapshot: MemorySnapshot?
    private(set) var history: [MemorySample] = []

    private let samplingInterval: TimeInterval = 1
    private let historyWindow: TimeInterval = 60 * 60

    /// Runs until the enclosing task is cancelled (e.g. by SwiftUI's `.task` modifier).
    func start() async {
        while !Task.isCancelled {
            if let newSnapshot = MemorySampling.readSnapshot() {
                snapshot = newSnapshot
                let now = Date()
                history.append(MemorySample(date: now, snapshot: newSnapshot))
                history = Self.trimmedHistory(history, keeping: historyWindow, relativeTo: now)
            }
            try? await Task.sleep(for: .seconds(samplingInterval))
        }
    }

    /// Mirrors `CPUMonitor.trimmedHistory` — see its comment for why this is
    /// `nonisolated static` (unit-testable with synthetic timestamps).
    nonisolated static func trimmedHistory(
        _ history: [MemorySample],
        keeping window: TimeInterval,
        relativeTo now: Date
    ) -> [MemorySample] {
        let oldestKept = now.addingTimeInterval(-window)
        return history.filter { $0.date >= oldestKept }
    }
}
