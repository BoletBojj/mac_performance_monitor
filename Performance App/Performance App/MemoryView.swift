import SwiftUI
import Charts

struct MemoryView: View {
    @State private var monitor = MemoryMonitor()
    @State private var client = ProcessHelperClient()
    @State private var selectedRange: HistoryRange = .fifteenMinutes
    @State private var showSpread = true
    @State private var remoteHistory: [MemoryHistoryPoint] = []
    @State private var sinceBootHistory: [MemoryHistoryPoint] = []
    @State private var peaks: [PeakRecord] = []

    private var bootTime: Date? { SystemClock.bootTime() }

    private var displayedHistory: [MemoryHistoryPoint] {
        remoteHistory.isEmpty ? monitor.history.map(MemoryHistoryPoint.fallback) : remoteHistory
    }

    private var sinceBootLabel: String {
        guard let bootTime else { return "Peak (24h)" }
        return Date().timeIntervalSince(bootTime) < HistoryRange.twentyFourHours.duration ? "Peak since boot" : "Peak (24h)"
    }

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

                    Divider()

                    HistoryRangeControls(selectedRange: $selectedRange, showSpread: $showSpread)

                    if remoteHistory.isEmpty {
                        Text("Showing this session only — background recording unavailable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    MemoryHistoryChart(history: displayedHistory, range: selectedRange, showSpread: showSpread)

                    peaksRow
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
        .task {
            client.registerHelperIfNeeded()
        }
        .task(id: selectedRange) {
            while !Task.isCancelled {
                await refreshHistory()
                try? await Task.sleep(for: .seconds(selectedRange.refreshInterval))
            }
        }
        .task {
            while !Task.isCancelled {
                await refreshSinceBootAndPeaks()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var peaksRow: some View {
        HStack(alignment: .top) {
            PeakBadge(
                label: "Peak in range",
                value: Self.formattedBytes(UInt64(displayedHistory.map(\.used.max).max() ?? 0)),
                date: nil
            )
            PeakBadge(
                label: sinceBootLabel,
                value: Self.formattedBytes(UInt64(sinceBootHistory.map(\.used.max).max() ?? 0)),
                date: nil
            )
            if let allTime = peaks.first(where: { $0.metric == .memoryUsed }) {
                PeakBadge(label: "All-time high", value: Self.formattedBytes(UInt64(allTime.value)), date: allTime.date)
            } else {
                PeakBadge(label: "All-time high", value: "—", date: nil)
            }
            Button("Reset") {
                Task {
                    await client.resetPeaks()
                    peaks = await client.fetchPeaks()
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }

    private func refreshHistory() async {
        let now = Date()
        let since = selectedRange.effectiveStart(now: now, bootTime: bootTime)
        remoteHistory = await client.fetchMemoryHistory(since: since, bucketSeconds: selectedRange.bucketSeconds)
    }

    private func refreshSinceBootAndPeaks() async {
        let now = Date()
        let since = HistoryRange.twentyFourHours.effectiveStart(now: now, bootTime: bootTime)
        sinceBootHistory = await client.fetchMemoryHistory(since: since, bucketSeconds: HistoryRange.twentyFourHours.bucketSeconds)
        peaks = await client.fetchPeaks()
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

    /// The four categories stacked in the history chart — `.free` isn't part
    /// of "used" memory, matching `MemorySnapshot.usedBytes`'s definition.
    static let stacked: [MemoryCategory] = [.active, .inactive, .wired, .compressed]

    func value(in point: MemoryHistoryPoint) -> Double {
        switch self {
        case .active: point.active
        case .inactive: point.inactive
        case .wired: point.wired
        case .compressed: point.compressed
        case .free: 0
        }
    }
}

private extension MemoryHistoryPoint {
    /// Wraps a single live sample as a degenerate one-sample "bucket", the
    /// same way `CPUHistoryPoint.fallback` does for the CPU chart.
    static func fallback(_ sample: MemorySample) -> MemoryHistoryPoint {
        let used = Double(sample.snapshot.usedBytes)
        return MemoryHistoryPoint(
            date: sample.date,
            active: Double(sample.snapshot.activeBytes),
            inactive: Double(sample.snapshot.inactiveBytes),
            wired: Double(sample.snapshot.wiredBytes),
            compressed: Double(sample.snapshot.compressedBytes),
            used: BucketStats(count: 1, sum: used, sumOfSquares: used * used, min: used, max: used)
        )
    }
}

private struct MemoryStackSample: Identifiable {
    let date: Date
    let category: MemoryCategory
    let bytes: Double

    var id: String { "\(date.timeIntervalSince1970)-\(category.label)" }
}

private struct MemoryHistoryChart: View {
    let history: [MemoryHistoryPoint]
    let range: HistoryRange
    let showSpread: Bool

    @State private var hoveredPoint: MemoryHistoryPoint?

    private var latestDate: Date { history.last?.date ?? Date() }
    private var strideSeconds: Double { ChartTimeAxis.strideSeconds(forWindowSeconds: range.duration) }

    private var stackedSamples: [MemoryStackSample] {
        history.flatMap { point in
            MemoryCategory.stacked.map { category in
                MemoryStackSample(date: point.date, category: category, bytes: category.value(in: point))
            }
        }
    }

    /// A gap longer than ~2.5 buckets is treated as a real break (sleep, the
    /// helper being unreachable) rather than ordinary timing jitter.
    ///
    /// Only applied to the dashed peak line below, not the stacked area: the
    /// stack already uses `foregroundStyle(by:)` to group its four category
    /// layers, and adding a second, per-segment `series` to the same marks
    /// would fight that grouping. A gap in the stacked fill is the one
    /// accepted visual gap in this view — rare in practice (sleep/helper
    /// downtime), and the dashed line and hover tooltip still show it correctly.
    private var segments: [[MemoryHistoryPoint]] {
        HistoryGapSegmentation.segments(history, maxGap: range.bucketSeconds * 2.5)
    }

    /// Scales to the busiest *max* used-memory point on screen, not the
    /// stack's mean total, so the dashed peak line is never clipped.
    private var yUpperBound: Double {
        let maxValue = history.reduce(0.0) { max($0, $1.used.max) }
        return max(1, maxValue * 1.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Memory Over Time")
                    .font(.headline)
                Spacer()
                if let hoveredPoint {
                    Text(hoverSummary(for: hoveredPoint))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Chart {
                ForEach(stackedSamples) { sample in
                    AreaMark(
                        x: .value("Time", sample.date.timeIntervalSince(latestDate)),
                        y: .value("Bytes", sample.bytes),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Category", sample.category.label))
                }

                if showSpread {
                    ForEach(Array(segments.enumerated()), id: \.offset) { segmentIndex, segment in
                        ForEach(segment) { point in
                            LineMark(
                                x: .value("Time", point.date.timeIntervalSince(latestDate)),
                                y: .value("Peak Used", point.used.max),
                                series: .value("Segment", "peak-\(segmentIndex)")
                            )
                        }
                    }
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .chartForegroundStyleScale([
                MemoryCategory.active.label: MemoryCategory.active.color,
                MemoryCategory.inactive.label: MemoryCategory.inactive.color,
                MemoryCategory.wired.label: MemoryCategory.wired.color,
                MemoryCategory.compressed.label: MemoryCategory.compressed.color,
            ])
            .chartXScale(domain: -range.duration...0)
            .chartXAxis {
                AxisMarks(values: ChartTimeAxis.tickValues(windowSeconds: range.duration, strideSeconds: strideSeconds)) { value in
                    AxisGridLine()
                    AxisTick()
                    if let seconds = value.as(Double.self) {
                        AxisValueLabel(ChartTimeAxis.tickLabel(forSecondsAgo: seconds))
                    }
                }
            }
            .chartYScale(domain: 0...yUpperBound)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    if let bytes = value.as(Double.self) {
                        AxisValueLabel(MemoryView.formattedBytes(UInt64(max(bytes, 0))))
                    }
                }
            }
            .chartXAxisLabel("Time")
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hoveredPoint = nearestPoint(to: location, proxy: proxy, geometry: geometry)
                            case .ended:
                                hoveredPoint = nil
                            }
                        }
                }
            }
            .frame(height: 180)
        }
    }

    private func nearestPoint(to location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> MemoryHistoryPoint? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        guard let secondsAgo: Double = proxy.value(atX: location.x - origin.x) else { return nil }
        return history.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(latestDate) - secondsAgo) < abs(rhs.date.timeIntervalSince(latestDate) - secondsAgo)
        }
    }

    private func hoverSummary(for point: MemoryHistoryPoint) -> String {
        let stats = point.used
        return "used \(MemoryView.formattedBytes(UInt64(stats.mean)))  min \(MemoryView.formattedBytes(UInt64(stats.min)))  max \(MemoryView.formattedBytes(UInt64(stats.max)))"
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
