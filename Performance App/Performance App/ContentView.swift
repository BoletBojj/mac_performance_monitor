import SwiftUI

private enum SidebarItem: String, CaseIterable, Identifiable {
    case cpu = "CPU Load"
    case memory = "Memory"
    case processes = "Processes"
    case hardware = "Hardware Info"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .processes: "list.bullet.rectangle"
        case .hardware: "desktopcomputer"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .cpu

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationTitle("Monitor")
        } detail: {
            switch selection {
            case .cpu:
                CPULoadView()
            case .memory:
                MemoryView()
            case .processes:
                ProcessesView()
            case .hardware:
                HardwareInfoView()
            case nil:
                Text("Select a section")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
}
