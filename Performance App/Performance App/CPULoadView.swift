import SwiftUI
import Charts

struct CPULoadView: View {
    @State private var monitor = CPUMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("CPU Load")
                    .font(.title2)
                    .bold()

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

                CPUHistoryChart(
                    history: monitor.history,
                    hasCoreSplit: monitor.performanceUsage != nil
                )

                Divider()

                ForEach(monitor.coreLoads) { core in
                    LoadRow(
                        label: core.type.label(index: core.displayIndex),
                        usage: core.usage,
                        help: core.type.explanation
                    )
                }
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 520)
        .task {
            await monitor.start()
        }
    }
}

private struct CPUHistoryChart: View {
    let history: [CPULoadSample]
    let hasCoreSplit: Bool

    private static let windowMinutes: Double = 60

    /// Anchoring "now" to the newest sample (rather than `Date()`) pins the
    /// most recent point exactly at x = 0 regardless of render timing.
    private var latestDate: Date { history.last?.date ?? Date() }

    /// Scales to the busiest moment currently on screen (with headroom),
    /// instead of always spanning the full core count — idle periods stay
    /// readable instead of flatlining near the bottom of a mostly-empty chart.
    private var yUpperBound: Double {
        let maxValue = history.reduce(0.0) { running, sample in
            max(running, sample.overall, sample.performance ?? 0, sample.efficiency ?? 0)
        }
        return max(1, (maxValue * 1.2).rounded(.up))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Load Over Time")
                .font(.headline)

            Chart(history) { sample in
                let minutesAgo = sample.date.timeIntervalSince(latestDate) / 60

                LineMark(
                    x: .value("Minutes Ago", minutesAgo),
                    y: .value("Load", sample.overall)
                )
                .foregroundStyle(by: .value("Series", "Total"))

                if hasCoreSplit, let performance = sample.performance {
                    LineMark(
                        x: .value("Minutes Ago", minutesAgo),
                        y: .value("Load", performance)
                    )
                    .foregroundStyle(by: .value("Series", "Performance"))
                }

                if hasCoreSplit, let efficiency = sample.efficiency {
                    LineMark(
                        x: .value("Minutes Ago", minutesAgo),
                        y: .value("Load", efficiency)
                    )
                    .foregroundStyle(by: .value("Series", "Efficiency"))
                }
            }
            .chartXScale(domain: -Self.windowMinutes...0)
            .chartYScale(domain: 0...yUpperBound)
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel(format: FloatingPointFormatStyle<Double>.Percent())
                }
            }
            .chartXAxisLabel("Minutes Ago")
            .frame(height: 180)
        }
    }
}

private struct LoadRow: View {
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
    CPULoadView()
}
