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
