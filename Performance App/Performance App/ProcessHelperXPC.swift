import Foundation

/// Mach service name shared between the app (client) and the helper
/// daemon (listener). Must match the `MachServices` key in the daemon's
/// launchd plist exactly.
let processHelperMachServiceName = "com.performanceapp.helper"

/// NSXPC requires @objc-compatible signatures — not the app's own Swift
/// `ProcessUsage` struct. Replies are plain `[String: Any]` dictionaries
/// (String/Double only) rather than a custom class, specifically to avoid
/// `NSXPCInterface.setClasses` allow-listing, which is easy to get subtly
/// wrong and hard to verify without two real separate processes to test
/// against.
///
/// Kept deliberately identical in both the "Performance App" and
/// "Performance App Helper" targets; there's no shared-framework target
/// wiring it between them, so if you change one copy, change the other to
/// match. Keys: "name" (String), "cpuUsage" (Double).
@objc protocol ProcessHelperProtocol {
    func fetchTopProcesses(withReply reply: @escaping ([[String: Any]]) -> Void)
}
