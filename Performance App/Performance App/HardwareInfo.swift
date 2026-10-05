import Foundation

struct HardwareInfoItem: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

struct HardwareInfoSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [HardwareInfoItem]
}

enum HardwareInfo {
    /// Gathers hardware/system facts from the OS. Keys that don't exist on the
    /// current Mac (e.g. `hw.perflevel1.*` on a single-cluster chip) are simply
    /// omitted rather than guessed at.
    static func load() -> [HardwareInfoSection] {
        var processor: [HardwareInfoItem] = []
        if let chip = Sysctl.string("machdep.cpu.brand_string") {
            processor.append(HardwareInfoItem(label: "Chip", value: chip))
        }
        if let physical = Sysctl.int32("hw.physicalcpu") {
            processor.append(HardwareInfoItem(label: "Physical Cores", value: "\(physical)"))
        }
        if let logical = Sysctl.int32("hw.logicalcpu") {
            processor.append(HardwareInfoItem(label: "Logical Cores", value: "\(logical)"))
        }
        if let performanceCores = Sysctl.int32("hw.perflevel0.physicalcpu") {
            processor.append(HardwareInfoItem(label: "Performance Cores", value: "\(performanceCores)"))
        }
        if let efficiencyCores = Sysctl.int32("hw.perflevel1.physicalcpu") {
            processor.append(HardwareInfoItem(label: "Efficiency Cores", value: "\(efficiencyCores)"))
        }

        var memory: [HardwareInfoItem] = []
        if let memSize = Sysctl.uint64("hw.memsize") {
            memory.append(HardwareInfoItem(label: "Physical Memory", value: formattedBytes(memSize)))
        }
        memory.append(HardwareInfoItem(label: "Active Processors", value: "\(ProcessInfo.processInfo.activeProcessorCount)"))

        var system: [HardwareInfoItem] = []
        if let model = Sysctl.string("hw.model") {
            system.append(HardwareInfoItem(label: "Model Identifier", value: model))
        }
        system.append(HardwareInfoItem(label: "macOS Version", value: ProcessInfo.processInfo.operatingSystemVersionString))
        system.append(HardwareInfoItem(label: "Host Name", value: ProcessInfo.processInfo.hostName))
        system.append(HardwareInfoItem(label: "Uptime", value: formattedUptime(ProcessInfo.processInfo.systemUptime)))

        return [
            HardwareInfoSection(title: "Processor", items: processor),
            HardwareInfoSection(title: "Memory", items: memory),
            HardwareInfoSection(title: "System", items: system),
        ]
    }

    private static func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private static func formattedUptime(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "—"
    }
}
