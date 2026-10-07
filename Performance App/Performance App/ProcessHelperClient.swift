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
