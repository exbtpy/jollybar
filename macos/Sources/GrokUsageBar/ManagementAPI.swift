import Foundation

/// Developer-API ledger from the documented Management API.
/// This is not the SuperGrok weekly pool.
///
/// `prepaidTotalCents` is `total.val` from
/// `GET /v1/billing/teams/{team_id}/prepaid/balance`, sign preserved.
/// The documented example reports a purchase and the resulting total as
/// negative cent strings (`"-1000"`). This app shows that signed value
/// converted to dollars; it does not flip the sign.
///
/// `spend7dUSD` sums the numeric `values` of
/// `POST /v1/billing/teams/{team_id}/usage`. The documented example uses
/// `"name": "usd"` and the sample points are dollar amounts (0.75), not cents.
struct ManagementSnapshot: Equatable {
    let prepaidTotalCents: Int64?
    let spend7dUSD: Double?
}

enum ManagementParseError: Equatable, Error {
    case unreadable
    case unexpectedShape
}

enum ManagementAPIParser {
    static func parseBalance(_ data: Data) -> Result<Int64?, ManagementParseError> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.unreadable)
        }
        if root["total"] == nil || root["total"] is NSNull {
            return .success(nil)
        }
        guard let cents = JSONValues.cents(root["total"]) else {
            return .failure(.unexpectedShape)
        }
        return .success(cents)
    }

    static func parseSpend(_ data: Data) -> Result<Double, ManagementParseError> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.unreadable)
        }
        guard let series = root["timeSeries"] as? [Any] else {
            return .failure(.unexpectedShape)
        }
        var total = 0.0
        for entry in series {
            guard let object = entry as? [String: Any] else { continue }
            guard let points = object["dataPoints"] as? [Any] else { continue }
            for point in points {
                guard let pointObject = point as? [String: Any],
                      let values = pointObject["values"] as? [Any] else {
                    continue
                }
                for value in values {
                    if let number = JSONValues.double(value) {
                        total += number
                    }
                }
            }
        }
        return .success(total)
    }
}

enum USDFormat {
    static func cents(_ cents: Int64) -> String {
        let dollars = Decimal(cents) / Decimal(100)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: dollars as NSDecimalNumber)
            ?? "$\(dollars)"
    }

    static func amount(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "$%.2f", value)
    }
}
