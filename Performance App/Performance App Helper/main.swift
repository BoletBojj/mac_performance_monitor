import Foundation

/// Runs as root (via launchd), so the per-process `libproc` calls in
/// `ProcessSampling` that returned EPERM for the unprivileged main app
/// succeed here. All the actual sampling/recording work happens in
/// `HistoryRecorder`; this type is just the XPC-facing adapter.
final class ProcessHelperService: NSObject, ProcessHelperProtocol {
    private let recorder: HistoryRecorder

    init(recorder: HistoryRecorder) {
        self.recorder = recorder
    }

    func fetchTopProcesses(withReply reply: @escaping ([[String: Any]]) -> Void) {
        recorder.fetchTopProcesses(reply: reply)
    }

    func fetchCPUHistory(since: Date, bucketSeconds: Double, withReply reply: @escaping (Data) -> Void) {
        recorder.fetchCPUHistory(since: since, bucketSeconds: bucketSeconds, reply: reply)
    }

    func fetchMemoryHistory(since: Date, bucketSeconds: Double, withReply reply: @escaping (Data) -> Void) {
        recorder.fetchMemoryHistory(since: since, bucketSeconds: bucketSeconds, reply: reply)
    }

    func fetchProcessSummary(since: Date, limit: Int, withReply reply: @escaping (Data) -> Void) {
        recorder.fetchProcessSummary(since: since, limit: limit, reply: reply)
    }

    func fetchPeaks(withReply reply: @escaping (Data) -> Void) {
        recorder.fetchPeaks(reply: reply)
    }

    func resetPeaks(withReply reply: @escaping (Bool) -> Void) {
        recorder.resetPeaks(reply: reply)
    }
}

final class ProcessHelperDelegate: NSObject, NSXPCListenerDelegate {
    let recorder: HistoryRecorder

    init(recorder: HistoryRecorder) {
        self.recorder = recorder
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ProcessHelperProtocol.self)
        newConnection.exportedObject = ProcessHelperService(recorder: recorder)
        newConnection.resume()
        return true
    }
}

// The database directory is root-owned (this process always runs as root),
// which is fine: the app never touches the file directly, only through XPC.
let supportDirectory = "/Library/Application Support/com.performanceapp.helper"
try? FileManager.default.createDirectory(atPath: supportDirectory, withIntermediateDirectories: true)

let store = try! HistoryStore(path: supportDirectory + "/history.sqlite")
let recorder = HistoryRecorder(store: store)
recorder.start()

let delegate = ProcessHelperDelegate(recorder: recorder)
let listener = NSXPCListener(machServiceName: processHelperMachServiceName)
listener.delegate = delegate
listener.resume()

RunLoop.current.run() // launchd manages this process's lifecycle from here
