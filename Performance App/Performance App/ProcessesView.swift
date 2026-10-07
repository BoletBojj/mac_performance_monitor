import SwiftUI

struct ProcessesView: View {
    @State private var client = ProcessHelperClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Top Processes")
                        .font(.title2)
                        .bold()

                    Spacer()

                    // Dev-only control: needed whenever the helper's own code
                    // changes, since BackgroundTaskManagement pins the
                    // approved binary by checksum (see
                    // ProcessHelperClient.unregisterHelper).
                    Button("Unregister Helper (dev)") {
                        client.unregisterHelper()
                    }
                    .font(.caption)
                }

                statusView

                if !client.topProcesses.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(client.topProcesses) { process in
                            ProcessRow(process: process)
                        }
                    }
                } else if client.registrationStatus == .registered {
                    Text("Gathering process data…")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 460)
        .task {
            await client.start()
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch client.registrationStatus {
        case .notRegistered:
            Text("Not registered yet.")
                .foregroundStyle(.secondary)
        case .registered:
            EmptyView()
        case .requiresApproval:
            Text("Registered — needs approval in System Settings → General → Login Items & Extensions.")
                .foregroundStyle(.orange)
        case .failed(let message):
            Text("Registration failed: \(message)")
                .foregroundStyle(.red)
        }
    }
}

private struct ProcessRow: View {
    let process: ProcessUsageSnapshot

    var body: some View {
        HStack {
            Text(process.name)
                .frame(width: 180, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            ProgressView(value: min(process.cpuUsage, 1))
                .tint(color(for: process.cpuUsage))

            Text(process.cpuUsage, format: .percent.precision(.fractionLength(1)))
                .frame(width: 64, alignment: .trailing)
                .monospacedDigit()
        }
    }

    private func color(for usage: Double) -> Color {
        switch usage {
        case ..<0.5: .green
        case ..<0.8: .yellow
        default: .red
        }
    }
}

#Preview {
    ProcessesView()
}
