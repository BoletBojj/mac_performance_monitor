import SwiftUI

struct MemoryView: View {
    @State private var monitor = MemoryMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Memory")
                    .font(.title2)
                    .bold()

                if let snapshot = monitor.snapshot {
                    UsedMemoryRow(snapshot: snapshot)

                    Divider()

                    ForEach(MemoryCategory.allCases, id: \.self) { category in
                        MemoryCategoryRow(category: category, bytes: category.bytes(in: snapshot))
                    }

                    Divider()

                    LabeledContent("Physical Memory", value: Self.formattedBytes(snapshot.totalBytes))
                    if snapshot.swapTotalBytes > 0 {
                        LabeledContent(
                            "Swap Used",
                            value: "\(Self.formattedBytes(snapshot.swapUsedBytes)) of \(Self.formattedBytes(snapshot.swapTotalBytes))"
                        )
                    }
                } else {
                    Text("Gathering memory data…")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 460)
        .task {
            await monitor.start()
        }
    }

    static func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

private extension MemoryCategory {
    var color: Color {
        switch self {
        case .active: .green
        case .inactive: .yellow
        case .wired: .red
        case .compressed: .purple
        case .free: Color.secondary.opacity(0.25)
        }
    }
}

private struct UsedMemoryRow: View {
    let snapshot: MemorySnapshot

    var body: some View {
        HStack {
            Text("Used")
                .frame(width: 80, alignment: .leading)
                .monospacedDigit()

            SegmentedUsageBar(snapshot: snapshot)

            Text(snapshot.usedFraction, format: .percent.precision(.fractionLength(1)))
                .frame(width: 56, alignment: .trailing)
                .monospacedDigit()
        }
    }
}

/// A single bar split into one colored segment per `MemoryCategory`, each
/// sized as a fraction of total physical memory (not of `usedBytes`), so the
/// unfilled remainder visually reads as "free / uncounted" — matching the
/// single percentage shown next to it.
private struct SegmentedUsageBar: View {
    let snapshot: MemorySnapshot

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(MemoryCategory.allCases, id: \.self) { category in
                    let bytes = category.bytes(in: snapshot)
                    let fraction = snapshot.totalBytes > 0 ? Double(bytes) / Double(snapshot.totalBytes) : 0
                    Rectangle()
                        .fill(category.color)
                        .frame(width: max(geometry.size.width * fraction, 0))
                        .help("\(category.label): \(MemoryView.formattedBytes(bytes))\n\n\(category.explanation)")
                }
            }
        }
        .frame(height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
    }
}

private struct MemoryCategoryRow: View {
    let category: MemoryCategory
    let bytes: UInt64

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Circle()
                    .fill(category.color)
                    .frame(width: 8, height: 8)
                Text(category.label)
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(category.explanation)
            }
            .frame(width: 160, alignment: .leading)

            Spacer()

            Text(MemoryView.formattedBytes(bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    MemoryView()
}
