import Foundation
import Darwin

struct MemorySnapshot: Equatable {
    let totalBytes: UInt64
    let freeBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let swapUsedBytes: UInt64
    let swapTotalBytes: UInt64

    /// Active + inactive + wired + compressed — deliberately *not*
    /// `totalBytes - freeBytes`. macOS caches aggressively, so "free" is
    /// often tiny even when plenty of memory is actually available; raw
    /// free/used is a well-known trap for a macOS memory readout.
    var usedBytes: UInt64 {
        activeBytes + inactiveBytes + wiredBytes + compressedBytes
    }

    var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

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

@MainActor
@Observable
final class MemoryMonitor {
    private(set) var snapshot: MemorySnapshot?

    private let samplingInterval: TimeInterval = 1

    /// Runs until the enclosing task is cancelled (e.g. by SwiftUI's `.task` modifier).
    func start() async {
        while !Task.isCancelled {
            snapshot = Self.readSnapshot()
            try? await Task.sleep(for: .seconds(samplingInterval))
        }
    }

    /// Reads system-wide (not per-process) virtual memory statistics via the
    /// Mach API `host_statistics64` — the same category of API as
    /// `CPUMonitor`'s `host_processor_info`, not the per-process `libproc`
    /// family that turned out to require privileges this app doesn't have.
    private nonisolated static func readSnapshot() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        guard let totalBytes = Sysctl.uint64("hw.memsize") else { return nil }

        let pageSize = UInt64(vm_page_size)

        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0)

        return MemorySnapshot(
            totalBytes: totalBytes,
            freeBytes: UInt64(stats.free_count) * pageSize,
            activeBytes: UInt64(stats.active_count) * pageSize,
            inactiveBytes: UInt64(stats.inactive_count) * pageSize,
            wiredBytes: UInt64(stats.wire_count) * pageSize,
            compressedBytes: UInt64(stats.compressor_page_count) * pageSize,
            swapUsedBytes: swapResult == 0 ? UInt64(swapUsage.xsu_used) : 0,
            swapTotalBytes: swapResult == 0 ? UInt64(swapUsage.xsu_total) : 0
        )
    }
}
