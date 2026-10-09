import SwiftUI
import Charts

/// Historical trends only — CPU and GPU load over a selectable range, sharing
/// one range picker. Live "right now" numbers (CPU's per-core breakdown and
/// GPU's single aggregate row alike) live on `CoreActivityView` instead; this
/// page is purely about what happened over time, which is why CPU and GPU —
/// two otherwise unrelated screens' worth of live data — share a page here:
/// they're both just "a load percentage over time" from the chart's point of
/// view.
struct PerformanceHistoryView: View {
    /// A local, non-displayed `CPUMonitor` purely so this page can fall back
    /// to in-session local history when the helper's recorded CPU history
    /// isn't available — the live per-core breakdown it also produces is
    /// simply never read here. `CoreActivityView` has its own separate
    /// instance; per this app's "no shared app-wide model" convention, two
    /// independent instances is the expected shape, not a duplication bug —
    /// `NavigationSplitView` only ever instantiates the one currently-visible
    /// detail view anyway, so there's no real double-polling in practice.
    @State private var cpuMonitor = CPUMonitor()
    @State private var client = ProcessHelperClient()
    @State private var selectedRange: HistoryRange = .fifteenMinutes
    @State private var showSpread = true
    @State private var remoteHistory: [CPUHistoryPoint] = []
    @State private var sinceBootHistory: [CPUHistoryPoint] = []
    @State private var peaks: [PeakRecord] = []
    @State private var gpuHistory: [GPULoadHistoryPoint] = []

    private var bootTime: Date? { SystemClock.bootTime() }

    /// Falls back to the app's own local, in-memory-only history (lost on
    /// quit) whenever the helper hasn't returned recorded data — either it
    /// isn't registered, isn't reachable, or (briefly, right after boot)
    /// just hasn't recorded anything yet.
    private var displayedHistory: [CPUHistoryPoint] {
        remoteHistory.isEmpty ? cpuMonitor.history.map(CPUHistoryPoint.fallback) : remoteHistory
    }

    private var sinceBootLabel: String {
        guard let bootTime else { return "Peak (24h)" }
        return Date().timeIntervalSince(bootTime) < HistoryRange.twentyFourHours.duration ? "Peak since boot" : "Peak (24h)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Performance History")
                    .font(.title2)
                    .bold()

                HistoryRangeControls(selectedRange: $selectedRange, showSpread: $showSpread)

                if remoteHistory.isEmpty {
                    Text("Showing this session only — background recording unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("CPU").font(.headline)

                CPUHistoryChart(
                    history: displayedHistory,
                    range: selectedRange,
                    showSpread: showSpread,
                    hasCoreSplit: cpuMonitor.performanceUsage != nil
                )

                cpuPeaksRow

                Divider()

                Text("GPU").font(.headline)

                if gpuHistory.isEmpty {
                    Text("No GPU data yet — recorded via the background helper (powermetrics).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    GPUHistoryChart(history: gpuHistory, range: selectedRange, showSpread: showSpread)
                }
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 520)
        .task {
            await cpuMonitor.start()
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

    private var cpuPeaksRow: some View {
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
        gpuHistory = await client.fetchGPUHistory(since: since, bucketSeconds: selectedRange.bucketSeconds)
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

/// Mirrors `CPUHistoryChart`'s shape but for a single series (GPU has no
/// Performance/Efficiency split) — same range/spread/gap-segmentation/hover
/// conventions, reused directly rather than duplicated differently.
private struct GPUHistoryChart: View {
    let history: [GPULoadHistoryPoint]
    let range: HistoryRange
    let showSpread: Bool

    @State private var hoveredPoint: GPULoadHistoryPoint?

    private var latestDate: Date { history.last?.date ?? Date() }
    private var strideSeconds: Double { ChartTimeAxis.strideSeconds(forWindowSeconds: range.duration) }

    private var segments: [[GPULoadHistoryPoint]] {
        HistoryGapSegmentation.segments(history, maxGap: range.bucketSeconds * 2.5)
    }

    private var yUpperBound: Double {
        let maxValue = history.reduce(0.0) { max($0, $1.load.max) }
        return max(0.1, min(1, (maxValue * 1.2)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("GPU Load Over Time")
                    .font(.headline)
                Spacer()
                if let hoveredPoint {
                    Text(hoverSummary(for: hoveredPoint))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Chart {
                ForEach(Array(segments.enumerated()), id: \.offset) { segmentIndex, segment in
                    ForEach(segment) { point in
                        let secondsAgo = point.date.timeIntervalSince(latestDate)

                        if showSpread {
                            AreaMark(
                                x: .value("Time", secondsAgo),
                                yStart: .value("Min", point.load.min),
                                yEnd: .value("Max", point.load.max),
                                series: .value("Segment", "envelope-\(segmentIndex)")
                            )
                            .foregroundStyle(Color.purple.opacity(0.1))
                            .interpolationMethod(.monotone)

                            AreaMark(
                                x: .value("Time", secondsAgo),
                                yStart: .value("-1\u{03c3}", point.load.lowerBand),
                                yEnd: .value("+1\u{03c3}", point.load.upperBand),
                                series: .value("Segment", "band-\(segmentIndex)")
                            )
                            .foregroundStyle(Color.purple.opacity(0.22))
                            .interpolationMethod(.monotone)
                        }

                        LineMark(
                            x: .value("Time", secondsAgo),
                            y: .value("Load", point.load.mean),
                            series: .value("Segment", "load-\(segmentIndex)")
                        )
                        .foregroundStyle(Color.purple)
                        .interpolationMethod(.monotone)
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
            .frame(height: 140)
        }
    }

    private func nearestPoint(to location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> GPULoadHistoryPoint? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        guard let secondsAgo: Double = proxy.value(atX: location.x - origin.x) else { return nil }
        return history.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(latestDate) - secondsAgo) < abs(rhs.date.timeIntervalSince(latestDate) - secondsAgo)
        }
    }

    private func hoverSummary(for point: GPULoadHistoryPoint) -> String {
        let stats = point.load
        var summary = "mean \(formattedPercent(stats.mean))  \u{b1}\(formattedPercent(stats.stdDev))  min \(formattedPercent(stats.min))  max \(formattedPercent(stats.max))"
        if let power = point.power {
            summary += "  (\(Int(power.mean)) mW)"
        }
        return summary
    }
}

#Preview {
    PerformanceHistoryView()
}
