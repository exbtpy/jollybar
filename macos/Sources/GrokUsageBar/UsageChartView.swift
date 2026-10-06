import SwiftUI
import Charts

struct UsageChartView: View {
    @ObservedObject var historyService: UsageHistoryService
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

            if points.isEmpty {
                Text("No history data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                chartView(points: points)
            }
        }
    }

    @ViewBuilder
    private func chartView(points: [UsageDataPoint]) -> some View {
        let interpolated = hoverDate.flatMap { date in
            hoveredValues(at: date, in: points)
        }

        Chart {
            ForEach(points.filter { $0.pctBot != nil }) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage", (point.pctBot ?? 0) * 100)
                )
                .foregroundStyle(by: .value("Window", "Grok Bot"))
                .interpolationMethod(.catmullRom)
            }

            ForEach(points.filter(\.includesWeekly)) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage", point.pctWeekly * 100)
                )
                .foregroundStyle(by: .value("Window", "Weekly"))
                .interpolationMethod(.catmullRom)
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
        .chartForegroundStyleScale([
            "Grok Bot": Color.blue,
            "Weekly": Color.orange
        ])
        .chartLegend(.visible)
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
        let weeklyPoints = points.filter(\.includesWeekly)
        let botPoints = points.compactMap { point -> UsageDataPoint? in
            guard let pctBot = point.pctBot else { return nil }
            return UsageDataPoint(timestamp: point.timestamp, pctWeekly: pctBot)
        }
        let weekly = UsageChartInterpolation.interpolateValues(at: date, in: weeklyPoints)
        let bot = UsageChartInterpolation.interpolateValues(at: date, in: botPoints)
        guard weekly != nil || bot != nil else { return nil }
        return UsageChartInterpolatedValues(
            date: date,
            pctWeekly: weekly?.pctWeekly ?? 0,
            pctBot: bot?.pctWeekly,
            showsWeekly: weekly != nil
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

    init(date: Date, pctWeekly: Double, pctBot: Double? = nil, showsWeekly: Bool = true) {
        self.date = date
        self.pctWeekly = pctWeekly
        self.pctBot = pctBot
        self.showsWeekly = showsWeekly
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
