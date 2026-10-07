import XCTest
@testable import Jollybar

final class UsageChartInterpolationTests: XCTestCase {
    func testInterpolateValuesClampsNegativeOvershootAfterReset() {
        let base = Date(timeIntervalSince1970: 0)
        let points = [
            UsageDataPoint(timestamp: base, pctWeekly: 0.3),
            UsageDataPoint(timestamp: base.addingTimeInterval(1), pctWeekly: 0.7),
            UsageDataPoint(timestamp: base.addingTimeInterval(2), pctWeekly: 0.0),
            UsageDataPoint(timestamp: base.addingTimeInterval(3), pctWeekly: 1.0),
        ]

        XCTAssertLessThan(
            UsageChartInterpolation.catmullRom(0.3, 0.7, 0.0, 1.0, t: 0.966),
            0
        )

        let interpolated = UsageChartInterpolation.interpolateValues(
            at: base.addingTimeInterval(1.966),
            in: points
        )

        XCTAssertEqual(interpolated?.pctWeekly, 0 as Double?)
    }

    func testInterpolateValuesClampsPositiveOvershootToHundredPercent() {
        let base = Date(timeIntervalSince1970: 0)
        let points = [
            UsageDataPoint(timestamp: base, pctWeekly: 0.0),
            UsageDataPoint(timestamp: base.addingTimeInterval(1), pctWeekly: 0.5),
            UsageDataPoint(timestamp: base.addingTimeInterval(2), pctWeekly: 1.0),
            UsageDataPoint(timestamp: base.addingTimeInterval(3), pctWeekly: 0.0),
        ]

        XCTAssertGreaterThan(
            UsageChartInterpolation.catmullRom(0.0, 0.5, 1.0, 0.0, t: 0.911),
            1
        )

        let interpolated = UsageChartInterpolation.interpolateValues(
            at: base.addingTimeInterval(1.911),
            in: points
        )

        XCTAssertEqual(interpolated?.pctWeekly, 1 as Double?)
    }
}
