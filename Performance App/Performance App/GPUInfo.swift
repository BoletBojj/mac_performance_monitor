import Foundation
import Metal

enum GPUInfo {
    /// One section per GPU in the system (Macs with a discrete + integrated
    /// GPU, or an eGPU attached, report more than one `MTLDevice`).
    static func load() -> [HardwareInfoSection] {
        let devices = MTLCopyAllDevices()
        guard !devices.isEmpty else {
            return [HardwareInfoSection(
                title: "GPU",
                items: [HardwareInfoItem(label: "Status", value: "No Metal-capable GPU found")]
            )]
        }

        return devices.map { device in
            var items: [HardwareInfoItem] = []
            items.append(HardwareInfoItem(label: "Name", value: device.name))
            items.append(HardwareInfoItem(label: "Architecture", value: device.architecture.name))
            items.append(HardwareInfoItem(label: "Unified Memory", value: device.hasUnifiedMemory ? "Yes" : "No"))
            items.append(HardwareInfoItem(
                label: "Recommended Max Working Set",
                value: formattedBytes(device.recommendedMaxWorkingSetSize)
            ))
            // These only mean something for discrete, non-unified-memory GPUs
            // (Intel Macs with a dGPU/eGPU); Apple Silicon has one GPU, and
            // Apple's own docs note the properties don't apply there.
            if !device.hasUnifiedMemory {
                items.append(contentsOf: discreteGPUFields(for: device))
            }
            items.append(HardwareInfoItem(label: "Metal 3 Support", value: device.supportsFamily(.metal3) ? "Yes" : "No"))

            let title = devices.count > 1 ? "GPU — \(device.name)" : "GPU"
            return HardwareInfoSection(title: title, items: items)
        }
    }

    @available(*, deprecated, message: "Intentionally touches discrete-GPU-only MTLDevice properties.")
    private static func discreteGPUFields(for device: MTLDevice) -> [HardwareInfoItem] {
        var items: [HardwareInfoItem] = []
        items.append(HardwareInfoItem(label: "Low Power", value: device.isLowPower ? "Yes" : "No"))
        items.append(HardwareInfoItem(label: "Removable (eGPU)", value: device.isRemovable ? "Yes" : "No"))
        if device.maxTransferRate > 0 {
            items.append(HardwareInfoItem(
                label: "Max Transfer Rate",
                value: formattedBytes(device.maxTransferRate) + "/s"
            ))
        }
        return items
    }

    private static func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
