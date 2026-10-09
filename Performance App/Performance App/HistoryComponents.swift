import SwiftUI

/// A small "label / value / date" block for peak/high-water-mark displays,
/// reused by the CPU, Memory, and Processes history views.
struct PeakBadge: View {
    let label: String
    let value: String
    let date: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit())
            if let date {
                Text(date, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Range picker + "Show spread" toggle, shared by the CPU and Memory history
/// charts so both stay in lockstep in look and feel.
struct HistoryRangeControls: View {
    @Binding var selectedRange: HistoryRange
    @Binding var showSpread: Bool

    var body: some View {
        HStack {
            Picker("Range", selection: $selectedRange) {
                ForEach(HistoryRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Toggle("Show spread", isOn: $showSpread)
                .toggleStyle(.checkbox)

            Spacer()
        }
    }
}

func formattedPercent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(0)))
}

/// Pure tick-generation/formatting logic shared by every history chart's X
/// axis (CPU, GPU, Memory) — pulled out so it's unit-testable without
/// rendering a `Chart`, and so each chart doesn't reimplement its own
/// slightly-different version.
///
/// The stride scales with the window instead of being a fixed 10 minutes,
/// since charts span four different `HistoryRange`s.
enum ChartTimeAxis {
    static func strideSeconds(forWindowSeconds window: Double) -> Double {
        switch window {
        case ..<(20 * 60): 5 * 60 // 15m range -> 5m ticks
        case ..<(2 * 60 * 60): 10 * 60 // 1h range -> 10m ticks
        case ..<(12 * 60 * 60): 60 * 60 // 6h range -> 1h ticks
        default: 4 * 60 * 60 // 24h range -> 4h ticks
        }
    }

    static func tickValues(windowSeconds: Double, strideSeconds: Double) -> [Double] {
        precondition(strideSeconds > 0, "stride must be positive")
        return Array(stride(from: -windowSeconds, through: 0, by: strideSeconds))
    }

    static func tickLabel(forSecondsAgo seconds: Double) -> String {
        let minutes = seconds / 60
        if abs(minutes) < 60 {
            // Round rather than truncate: Int(minutes) would silently
            // truncate toward zero for a non-whole-minute value (e.g.
            // -57.5 -> "-57m", the wrong neighbor).
            return "\(Int(minutes.rounded()))m"
        }
        let hours = (seconds / 3600).rounded()
        return "\(Int(hours))h"
    }
}
