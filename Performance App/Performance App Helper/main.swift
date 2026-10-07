import Foundation
import Darwin

/// Runs as root (via launchd), so the `libproc` calls that returned EPERM
/// for the sandboxed/unprivileged main app succeed here. Reuses the exact
/// enumeration/delta approach from the main app's (removed) ProcessMonitor.
final class ProcessHelperService: NSObject, ProcessHelperProtocol {
    private var previousTimes: [pid_t: UInt64] = [:]
    private var lastSampleDate: Date?

    func fetchTopProcesses(withReply reply: @escaping ([[String: Any]]) -> Void) {
        let now = Date()
        let currentTimes = Self.sampleProcessTimes()

        defer {
            previousTimes = currentTimes.mapValues(\.totalCPUTime)
            lastSampleDate = now
        }

        guard let lastSampleDate, !currentTimes.isEmpty else {
            reply([])
            return
        }
        let elapsed = now.timeIntervalSince(lastSampleDate)

        let top = ProcessRanking.topProcesses(
            from: currentTimes,
            previousTimes: previousTimes,
            elapsedSeconds: elapsed,
            limit: 15
        )
        reply(top.map { ["name": $0.name, "cpuUsage": $0.cpuUsage] })
    }

    private static func sampleProcessTimes() -> [pid_t: (name: String, totalCPUTime: UInt64)] {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)

        let capacity = 4096
        var pids = [pid_t](repeating: 0, count: capacity)
        let returnedBytes = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(capacity * MemoryLayout<pid_t>.size))
        }
        guard returnedBytes > 0 else { return [:] }
        let pidCount = min(Int(returnedBytes) / MemoryLayout<pid_t>.size, capacity)

        var result: [pid_t: (name: String, totalCPUTime: UInt64)] = [:]
        // `.prefix(pidCount)` already bounds this to the slots the syscall
        // actually populated, so a `pid > 0` filter here isn't guarding
        // against unused buffer tail — it was silently excluding the
        // legitimate PID 0, kernel_task, from every sample.
        for pid in pids.prefix(pidCount) {
            var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { continue }

            var usage = rusage_info_v2()
            let rusageResult = withUnsafeMutablePointer(to: &usage) { structPtr -> Int32 in
                structPtr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, reboundPtr)
                }
            }
            guard rusageResult == 0 else { continue }

            let userTime = ProcessRanking.nanoseconds(fromMachTicks: usage.ri_user_time, timebase: timebase)
            let systemTime = ProcessRanking.nanoseconds(fromMachTicks: usage.ri_system_time, timebase: timebase)
            result[pid] = (name: String(cString: nameBuffer), totalCPUTime: userTime + systemTime)
        }
        return result
    }
}

final class ProcessHelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ProcessHelperProtocol.self)
        newConnection.exportedObject = ProcessHelperService()
        newConnection.resume()
        return true
    }
}

let delegate = ProcessHelperDelegate()
let listener = NSXPCListener(machServiceName: processHelperMachServiceName)
listener.delegate = delegate
listener.resume()

RunLoop.current.run() // launchd manages this process's lifecycle from here
