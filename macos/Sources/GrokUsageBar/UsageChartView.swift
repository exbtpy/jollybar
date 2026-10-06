import SwiftUI
import Charts

struct UsageChartView: View {
    @ObservedObject var historyService: UsageHistoryService
    /// When false, the Weekly series is omitted. A grok.com account with no
    /// SuperGrok pool used to leave a 0% orange line in history.
    var showsWeeklyPool: Bool
    @State private var selectedRange: TimeRange = .day1
    @State private var hoverDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $selectedRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let points = historyService.downsampledPoints(for: selectedRange)
            let series = UsageChartSeries.displayPoints(
                from: points,
                includeWeekly: showsWeeklyPool,
                domain: selectedRange.interval
            )

            if series.isEmpty {
                Text("No history data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                chartView(points: points, series: series)
            }
        }
    }

    @ViewBuilder
    private func chartView(points: [UsageDataPoint], series: [UsageChartSeries.Point]) -> some View {
        let interpolated = hoverDate.flatMap { date in
            hoveredValues(at: date, in: points)
        }
        let seriesNames = UsageChartSeries.orderedNames(in: series)

        Chart {
            ForEach(series) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage", point.percent)
                )
                .foregroundStyle(by: .value("Window", point.series))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage", point.percent)
                )
                .foregroundStyle(by: .value("Window", point.series))
                .symbolSize(point.synthesized ? 16 : (point.series == UsageChartSeries.bot ? 64 : 110))
            }

            if let iv = interpolated {
                RuleMark(x: .value("Selected", iv.date))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                if iv.showsWeekly {
                    PointMark(
                        x: .value("Time", iv.date),
                        y: .value("Usage", iv.pctWeekly * 100)
                    )
                    .foregroundStyle(Color.orange)
                    .symbolSize(24)
                }
                if let pctBot = iv.pctBot {
                    PointMark(
                        x: .value("Time", iv.date),
                        y: .value("Usage", pctBot * 100)
                    )
                    .foregroundStyle(Color.blue)
                    .symbolSize(24)
                }
                if let pctModels = iv.pctCursorModels {
                    PointMark(
                        x: .value("Time", iv.date),
                        y: .value("Usage", pctModels * 100)
                    )
                    .foregroundStyle(Color.teal)
                    .symbolSize(24)
                }
            }
        }
        .chartXScale(domain: Date.now.addingTimeInterval(-selectedRange.interval)...Date.now)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)%")
                            .font(.caption2)
                    }
                }
                AxisGridLine()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel(format: xAxisFormat)
                    .font(.caption2)
                AxisGridLine()
            }
        }
        .chartForegroundStyleScale(
            domain: seriesNames,
            range: seriesNames.map { UsageChartSeries.color(for: $0) }
        )
        .chartLegend(seriesNames.isEmpty ? .hidden : .visible)
        .chartPlotStyle { plot in
            plot.clipped()
        }
        // Swift Charts maps the pointer onto the x scale itself and clears the
        // binding on exit — no plot-area coordinate math, and no `plotFrame`
        // to force-unwrap before the first layout pass.
        .chartXSelection(value: $hoverDate)
        .overlay(alignment: .top) {
            if let iv = interpolated {
                tooltipView(values: iv)
            }
        }
        .frame(height: 120)
        .padding(.top, 4)
    }

    private func hoveredValues(at date: Date, in points: [UsageDataPoint]) -> UsageChartInterpolatedValues? {
        let weeklyPoints = showsWeeklyPool ? points.filter(\.includesWeekly) : []
        let botPoints = points.compactMap { point -> UsageDataPoint? in
            guard let pctBot = point.pctBot else { return nil }
            return UsageDataPoint(timestamp: point.timestamp, pctWeekly: pctBot)
        }
        let modelPoints = points.compactMap { point -> UsageDataPoint? in
            guard let pct = point.pctCursorModels else { return nil }
            return UsageDataPoint(timestamp: point.timestamp, pctWeekly: pct)
        }
        let weekly = UsageChartInterpolation.interpolateValues(at: date, in: weeklyPoints)
        let bot = UsageChartInterpolation.interpolateValues(at: date, in: botPoints)
        let models = UsageChartInterpolation.interpolateValues(at: date, in: modelPoints)
        guard weekly != nil || bot != nil || models != nil else { return nil }
        return UsageChartInterpolatedValues(
            date: date,
            pctWeekly: weekly?.pctWeekly ?? 0,
            pctBot: bot?.pctWeekly,
            showsWeekly: weekly != nil,
            pctCursorModels: models?.pctWeekly,
            showsCursorModels: models != nil
        )
    }

    @ViewBuilder
    private func tooltipView(values: UsageChartInterpolatedValues) -> some View {
        VStack(spacing: 2) {
            Text(values.date, format: tooltipDateFormat)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            if let pctBot = values.pctBot {
                Text("Grok Bot \(Int(round(pctBot * 100)))%")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.blue)
            }
            if values.showsWeekly {
                Text("Weekly \(Int(round(values.pctWeekly * 100)))%")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
            }
            if values.showsCursorModels, let pct = values.pctCursorModels {
                Text("Cursor Models \(Int(round(pct * 100)))%")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.teal)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Formatting

    private var xAxisFormat: Date.FormatStyle {
        switch selectedRange {
        case .hour1:
            return .dateTime.hour().minute()
        case .hour6, .day1:
            return .dateTime.hour()
        case .day7:
            return .dateTime.weekday(.abbreviated)
        case .day30:
            return .dateTime.day().month(.abbreviated)
        }
    }

    private var tooltipDateFormat: Date.FormatStyle {
        switch selectedRange {
        case .hour1, .hour6, .day1:
            return .dateTime.hour().minute()
        case .day7:
            return .dateTime.weekday(.abbreviated).hour().minute()
        case .day30:
            return .dateTime.month(.abbreviated).day().hour()
        }
    }
}

struct UsageChartInterpolatedValues {
    let date: Date
    let pctWeekly: Double
    var pctBot: Double?
    var showsWeekly: Bool
    var pctCursorModels: Double?
    var showsCursorModels: Bool

    init(
        date: Date,
        pctWeekly: Double,
        pctBot: Double? = nil,
        showsWeekly: Bool = true,
        pctCursorModels: Double? = nil,
        showsCursorModels: Bool = false
    ) {
        self.date = date
        self.pctWeekly = pctWeekly
        self.pctBot = pctBot
        self.showsWeekly = showsWeekly
        self.pctCursorModels = pctCursorModels
        self.showsCursorModels = showsCursorModels
    }
}

enum UsageChartInterpolation {
    static func catmullRom(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    static func interpolateValues(at date: Date, in points: [UsageDataPoint]) -> UsageChartInterpolatedValues? {
        guard points.count >= 2 else { return nil }

        let sorted = points.sorted { $0.timestamp < $1.timestamp }

        if date < sorted.first!.timestamp || date > sorted.last!.timestamp {
            return UsageChartInterpolatedValues(date: date, pctWeekly: 0)
        }

        for i in 0..<(sorted.count - 1) {
            if date >= sorted[i].timestamp && date <= sorted[i + 1].timestamp {
                let span = sorted[i + 1].timestamp.timeIntervalSince(sorted[i].timestamp)
                let t = span > 0 ? date.timeIntervalSince(sorted[i].timestamp) / span : 0

                let i0 = max(0, i - 1)
                let i3 = min(sorted.count - 1, i + 2)

                let pctWeekly = catmullRom(
                    sorted[i0].pctWeekly, sorted[i].pctWeekly,
                    sorted[i + 1].pctWeekly, sorted[i3].pctWeekly, t: t
                )

                return UsageChartInterpolatedValues(
                    date: date,
                    pctWeekly: clampToUnitInterval(pctWeekly)
                )
            }
        }

        return nil
    }

    private static func clampToUnitInterval(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// One drawn sample. Each series gets its own id, because Swift Charts drops
/// marks that share a data-point id. A lone real sample is paired with a
/// display-only point a short time earlier so the line exists before the
/// second poll.
enum UsageChartSeries {
    struct Point: Identifiable {
        let id: String
        let timestamp: Date
        /// 0...100.
        let percent: Double
        let series: String
        /// True for the extra point that makes a one-sample series visible.
        let synthesized: Bool
    }

    static let bot = "Grok Bot"
    static let weekly = "Weekly"
    static let cursorModels = "Cursor Models"
    /// Legend order. Paint order is the reverse so the Grok Bot dot sits on top
    /// when Cursor Models is only a percent away.
    private static let legendOrder = [bot, weekly, cursorModels]
    private static let paintOrder = [cursorModels, weekly, bot]

    static func color(for series: String) -> Color {
        switch series {
        case bot: return .blue
        case weekly: return .orange
        case cursorModels: return .teal
        default: return .gray
        }
    }

    static func orderedNames(in points: [Point]) -> [String] {
        let present = Set(points.map(\.series))
        return legendOrder.filter(present.contains)
    }

    static func displayPoints(
        from dataPoints: [UsageDataPoint],
        includeWeekly: Bool,
        domain: TimeInterval
    ) -> [Point] {
        var grouped: [String: [Point]] = [:]
        for point in dataPoints {
            if let botFraction = point.pctBot {
                append(bot, fraction: botFraction, point: point, into: &grouped)
            }
            if includeWeekly, point.includesWeekly {
                append(weekly, fraction: point.pctWeekly, point: point, into: &grouped)
            }
            if let models = point.pctCursorModels {
                append(cursorModels, fraction: models, point: point, into: &grouped)
            }
        }

        // Long enough to read on a one-day axis, short enough not to invent a trend.
        let lead = min(max(domain * 0.08, 15 * 60), 3 * 60 * 60)
        var drawn: [Point] = []
        for name in paintOrder {
            guard var samples = grouped[name], !samples.isEmpty else { continue }
            samples.sort { $0.timestamp < $1.timestamp }
            if samples.count == 1, let only = samples.first {
                let anchor = Point(
                    id: only.id + "-lead",
                    timestamp: only.timestamp.addingTimeInterval(-lead),
                    percent: only.percent,
                    series: name,
                    synthesized: true
                )
                samples.insert(anchor, at: 0)
            }
            drawn.append(contentsOf: samples)
        }
        return drawn
    }

    private static func append(
        _ series: String,
        fraction: Double,
        point: UsageDataPoint,
        into grouped: inout [String: [Point]]
    ) {
        let sample = Point(
            id: "\(point.id.uuidString)-\(series)",
            timestamp: point.timestamp,
            percent: min(max(fraction, 0), 1) * 100,
            series: series,
            synthesized: false
        )
        grouped[series, default: []].append(sample)
    }
}
