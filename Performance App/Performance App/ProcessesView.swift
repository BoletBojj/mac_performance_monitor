import SwiftUI

struct ProcessesView: View {
    @State private var client = ProcessHelperClient()
    @State private var selectedRange: HistoryRange = .oneHour
    @State private var summary: [ProcessSummaryEntry] = []
    @State private var peaks: [PeakRecord] = []

    private var bootTime: Date? { SystemClock.bootTime() }

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

                Divider()

                summarySection
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 460)
        .task {
            await client.start()
        }
        .task(id: selectedRange) {
            while !Task.isCancelled {
                await refreshSummary()
                try? await Task.sleep(for: .seconds(selectedRange.refreshInterval))
            }
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

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top over selected range")
                    .font(.headline)
                Spacer()
                Picker("Range", selection: $selectedRange) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            Text("Answers \"what was hogging CPU?\" even if you weren't watching — requires the background helper to be running.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if summary.isEmpty {
                Text("No recorded data yet for this range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(summary) { entry in
                        ProcessSummaryRow(entry: entry)
                    }
                }
            }

            if let allTime = peaks.first(where: { $0.metric == .singleProcess }) {
                PeakBadge(
                    label: "All-time single-process peak",
                    value: "\(allTime.detail ?? "?") — \(formattedPercent(allTime.value))",
                    date: allTime.date
                )
            }
        }
    }

    private func refreshSummary() async {
        let now = Date()
        let since = selectedRange.effectiveStart(now: now, bootTime: bootTime)
        summary = await client.fetchProcessSummary(since: since, limit: 10)
        peaks = await client.fetchPeaks()
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

/// Shows average usage as a solid bar with a faint marker at the peak, so a
/// process that was briefly very busy but mostly idle still reads
/// differently from one that was steadily moderately busy.
private struct ProcessSummaryRow: View {
    let entry: ProcessSummaryEntry

    var body: some View {
        HStack {
            Text(entry.name)
                .frame(width: 180, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(for: entry.averageUsage))
                        .frame(width: geometry.size.width * min(entry.averageUsage, 1))

                    Rectangle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 2)
                        .offset(x: geometry.size.width * min(entry.peakUsage, 1) - 1)
                }
            }
            .frame(height: 8)
            .help("Peak \(formattedPercent(entry.peakUsage)) at \(entry.peakDate.formatted(date: .omitted, time: .standard))")

            Text(formattedPercent(entry.averageUsage))
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
