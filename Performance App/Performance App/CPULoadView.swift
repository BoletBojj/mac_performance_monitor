import SwiftUI
import Charts

struct CPULoadView: View {
    private static let samplingIntervalOptions: [TimeInterval] = [0.5, 1, 2, 5, 10]

    @State private var monitor = CPUMonitor()
    @State private var client = ProcessHelperClient()
    @State private var selectedRange: HistoryRange = .fifteenMinutes
    @State private var showSpread = true
    @State private var remoteHistory: [CPUHistoryPoint] = []
    @State private var sinceBootHistory: [CPUHistoryPoint] = []
    @State private var peaks: [PeakRecord] = []

    private var bootTime: Date? { SystemClock.bootTime() }

    /// Falls back to the app's own local, in-memory-only history (lost on
    /// quit) whenever the helper hasn't returned recorded data — either it
    /// isn't registered, isn't reachable, or (briefly, right after boot)
    /// just hasn't recorded anything yet.
    private var displayedHistory: [CPUHistoryPoint] {
        remoteHistory.isEmpty ? monitor.history.map(CPUHistoryPoint.fallback) : remoteHistory
    }

    private var sinceBootLabel: String {
        guard let bootTime else { return "Peak (24h)" }
        return Date().timeIntervalSince(bootTime) < HistoryRange.twentyFourHours.duration ? "Peak since boot" : "Peak (24h)"
    }

    var body: some View {
        @Bindable var monitor = monitor

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("CPU Load")
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

                HistoryRangeControls(selectedRange: $selectedRange, showSpread: $showSpread)

                if remoteHistory.isEmpty {
                    Text("Showing this session only — background recording unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                CPUHistoryChart(
                    history: displayedHistory,
                    range: selectedRange,
                    showSpread: showSpread,
                    hasCoreSplit: monitor.performanceUsage != nil
                )

                peaksRow

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
                value: formattedPercent(displayedHistory.map(\.overall.max).max() ?? 0),
                date: nil
            )
            PeakBadge(
                label: sinceBootLabel,
                value: formattedPercent(sinceBootHistory.map(\.overall.max).max() ?? 0),
                date: nil
            )
            if let allTime = peaks.first(where: { $0.metric == .cpuTotal }) {
                PeakBadge(label: "All-time high", value: formattedPercent(allTime.value), date: allTime.date)
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
        remoteHistory = await client.fetchCPUHistory(since: since, bucketSeconds: selectedRange.bucketSeconds)
    }

    private func refreshSinceBootAndPeaks() async {
        let now = Date()
        let since = HistoryRange.twentyFourHours.effectiveStart(now: now, bootTime: bootTime)
        sinceBootHistory = await client.fetchCPUHistory(since: since, bucketSeconds: HistoryRange.twentyFourHours.bucketSeconds)
        peaks = await client.fetchPeaks()
    }
}

private extension CPUHistoryPoint {
    /// Wraps a single live sample as a degenerate one-sample "bucket", so the
    /// chart can render the local-only fallback with the same type as real
    /// recorded history (spread collapses to a single point, as expected).
    static func fallback(_ sample: CPULoadSample) -> CPUHistoryPoint {
        func stats(_ value: Double) -> BucketStats {
            BucketStats(count: 1, sum: value, sumOfSquares: value * value, min: value, max: value)
        }
        return CPUHistoryPoint(
            date: sample.date,
            overall: stats(sample.overall),
            performance: sample.performance.map(stats),
            efficiency: sample.efficiency.map(stats)
        )
    }
}

/// Pure tick-generation/formatting logic for the history chart's X axis,
/// pulled out of `CPUHistoryChart` so it's unit-testable without rendering a
/// `Chart`. Internal (not private) — the view below it stays private.
///
/// Unlike the single fixed 60-minute window this replaced, the chart now
/// spans four different `HistoryRange`s, so the tick stride scales with the
/// window instead of always being 10 minutes.
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

private struct CPUHistoryChart: View {
    let history: [CPUHistoryPoint]
    let range: HistoryRange
    let showSpread: Bool
    let hasCoreSplit: Bool

    @State private var hoveredPoint: CPUHistoryPoint?

    private var latestDate: Date { history.last?.date ?? Date() }
    private var strideSeconds: Double { ChartTimeAxis.strideSeconds(forWindowSeconds: range.duration) }

    /// A gap longer than ~2.5 buckets is treated as a real break (sleep, the
    /// helper being unreachable) rather than ordinary timing jitter between
    /// consecutive buckets.
    private var segments: [[CPUHistoryPoint]] {
        HistoryGapSegmentation.segments(history, maxGap: range.bucketSeconds * 2.5)
    }

    /// Scales to the busiest *max*, not mean, currently on screen (with
    /// headroom) — using the mean here would clip the min-max envelope that
    /// `showSpread` draws.
    private var yUpperBound: Double {
        let maxValue = history.reduce(0.0) { running, point in
            max(running, point.overall.max, point.performance?.max ?? 0, point.efficiency?.max ?? 0)
        }
        return max(1, (maxValue * 1.2).rounded(.up))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Load Over Time")
                    .font(.headline)
                Spacer()
                if let hoveredPoint {
                    Text(hoverSummary(for: hoveredPoint))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Chart {
                // Each gap-separated run gets its own `series:` (so Charts
                // doesn't draw a straight line bridging a gap), while sharing
                // the same `foregroundStyle(by:)` value (so they still share
                // one legend entry and color).
                ForEach(Array(segments.enumerated()), id: \.offset) { segmentIndex, segment in
                    ForEach(segment) { point in
                        let secondsAgo = point.date.timeIntervalSince(latestDate)

                        if showSpread {
                            AreaMark(
                                x: .value("Time", secondsAgo),
                                yStart: .value("Min", point.overall.min),
                                yEnd: .value("Max", point.overall.max),
                                series: .value("Segment", "envelope-\(segmentIndex)")
                            )
                            .foregroundStyle(Color.accentColor.opacity(0.1))
                            .interpolationMethod(.monotone)

                            AreaMark(
                                x: .value("Time", secondsAgo),
                                yStart: .value("-1\u{03c3}", point.overall.lowerBand),
                                yEnd: .value("+1\u{03c3}", point.overall.upperBand),
                                series: .value("Segment", "band-\(segmentIndex)")
                            )
                            .foregroundStyle(Color.accentColor.opacity(0.22))
                            .interpolationMethod(.monotone)
                        }

                        LineMark(
                            x: .value("Time", secondsAgo),
                            y: .value("Load", point.overall.mean),
                            series: .value("Segment", "total-\(segmentIndex)")
                        )
                        .foregroundStyle(by: .value("Series", "Total"))
                        .interpolationMethod(.monotone)

                        if hasCoreSplit, let performance = point.performance {
                            LineMark(
                                x: .value("Time", secondsAgo),
                                y: .value("Load", performance.mean),
                                series: .value("Segment", "performance-\(segmentIndex)")
                            )
                            .foregroundStyle(by: .value("Series", "Performance"))
                            .interpolationMethod(.monotone)
                        }

                        if hasCoreSplit, let efficiency = point.efficiency {
                            LineMark(
                                x: .value("Time", secondsAgo),
                                y: .value("Load", efficiency.mean),
                                series: .value("Segment", "efficiency-\(segmentIndex)")
                            )
                            .foregroundStyle(by: .value("Series", "Efficiency"))
                            .interpolationMethod(.monotone)
                        }
                    }
                }
            }
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
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel(format: FloatingPointFormatStyle<Double>.Percent())
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

    private func nearestPoint(to location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> CPUHistoryPoint? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        guard let secondsAgo: Double = proxy.value(atX: location.x - origin.x) else { return nil }
        return history.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(latestDate) - secondsAgo) < abs(rhs.date.timeIntervalSince(latestDate) - secondsAgo)
        }
    }

    private func hoverSummary(for point: CPUHistoryPoint) -> String {
        let stats = point.overall
        return "mean \(formattedPercent(stats.mean))  \u{b1}\(formattedPercent(stats.stdDev))  min \(formattedPercent(stats.min))  max \(formattedPercent(stats.max))"
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
