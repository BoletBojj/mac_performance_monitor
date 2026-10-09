import SwiftUI

/// Live numbers only — current Total/Performance/Efficiency CPU load, the
/// per-core breakdown, and current GPU load, with the sampling-interval
/// picker. Historical charts for both CPU and GPU live on
/// `PerformanceHistoryView` instead; this split keeps "what's happening right
/// now" and "trends over time" from competing for space on one screen. GPU
/// has no per-core equivalent (no per-process or per-core GPU attribution is
/// available — see `PowerMetricsReader`), so it gets a single aggregate row
/// here rather than a breakdown section of its own.
struct CoreActivityView: View {
    private static let samplingIntervalOptions: [TimeInterval] = [0.5, 1, 2, 5, 10]

    @State private var monitor = CPUMonitor()
    @State private var client = ProcessHelperClient()
    @State private var latestGPULoad: Double?

    var body: some View {
        @Bindable var monitor = monitor

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Core Activity")
                        .font(.title2)
                        .bold()

                    Spacer()

                    Picker("Sample every", selection: $monitor.samplingInterval) {
                        ForEach(Self.samplingIntervalOptions, id: \.self) { interval in
                            Text("\(interval.formatted())s").tag(interval)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                LoadRow(
                    label: "Total",
                    usage: monitor.overallUsage,
                    capacity: Double(max(monitor.coreCount, 1)),
                    decimalPlaces: 1
                )
                if let performanceUsage = monitor.performanceUsage {
                    LoadRow(
                        label: "Performance",
                        usage: performanceUsage,
                        capacity: Double(monitor.performanceCoreCount),
                        help: CPUCoreType.performance.explanation,
                        decimalPlaces: 1
                    )
                }
                if let efficiencyUsage = monitor.efficiencyUsage {
                    LoadRow(
                        label: "Efficiency",
                        usage: efficiencyUsage,
                        capacity: Double(monitor.efficiencyCoreCount),
                        help: CPUCoreType.efficiency.explanation,
                        decimalPlaces: 1
                    )
                }

                Divider()

                ForEach(monitor.coreLoads) { core in
                    LoadRow(
                        label: core.type.label(index: core.displayIndex),
                        usage: core.usage,
                        help: core.type.explanation
                    )
                }

                Divider()

                if let latestGPULoad {
                    LoadRow(label: "GPU Load", usage: latestGPULoad, decimalPlaces: 1)
                } else {
                    Text("No GPU data yet — recorded via the background helper (powermetrics).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 520)
        .task {
            await monitor.start()
        }
        .task {
            client.registerHelperIfNeeded()
        }
        .task {
            while !Task.isCancelled {
                await refreshGPULoad()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Polls the helper's recently-recorded GPU history rather than reading
    /// `powermetrics` directly — the helper already owns that subprocess and
    /// samples on its own ~5s cadence, so this just asks for whatever's most
    /// recent instead of standing up a second reader.
    private func refreshGPULoad() async {
        let since = Date().addingTimeInterval(-30)
        let history = await client.fetchGPUHistory(since: since, bucketSeconds: 5)
        latestGPULoad = history.last?.load.mean
    }
}

struct LoadRow: View {
    let label: String
    let usage: Double
    var capacity: Double = 1 // the value that represents a "full" bar, e.g. core count for aggregate rows
    var help: String? = nil
    var decimalPlaces: Int = 0

    private var fractionFull: Double {
        capacity > 0 ? min(usage / capacity, 1) : 0
    }

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Text(label)
                if let help {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help(help)
                }
            }
            .frame(width: 170, alignment: .leading)
            .monospacedDigit()

            ProgressView(value: usage, total: capacity)
                .tint(color(for: fractionFull))

            Text(usage, format: .percent.precision(.fractionLength(decimalPlaces)))
                .frame(width: 56, alignment: .trailing)
                .monospacedDigit()
        }
    }

    private func color(for fractionFull: Double) -> Color {
        switch fractionFull {
        case ..<0.5: .green
        case ..<0.8: .yellow
        default: .red
        }
    }
}

#Preview {
    CoreActivityView()
}
