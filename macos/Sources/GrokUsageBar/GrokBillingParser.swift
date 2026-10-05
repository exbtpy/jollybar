import Foundation

/// One row of `config.productUsage`.
///
/// The official CLI struct (`BillingConfig` in xai-org/grok-build
/// `extensions/billing.rs`) does not declare `productUsage` — serde ignores it —
/// but a live response captured by claudia on 2026-08-10 includes it, and the
/// CLI's own unit fixture sends `{"product":"PRODUCT_GROK_BUILD","usagePercent":61.2}`.
/// Both name styles are accepted. A missing `usagePercent` is left nil (the
/// captured `GrokChat` entry had no percent).
struct GrokProductUsage: Equatable, Identifiable {
    let id: String
    let rawProduct: String
    let displayName: String
    let usagePercent: Double?
}

/// Parsed `GET /v1/billing?format=credits` body.
///
/// Field mapping is isolated here on purpose. Where a live account has not
/// confirmed a detail, the comment says so. Adjust this type rather than the UI.
struct GrokBillingReading: Equatable {
    /// Used percent of the shared weekly pool, 0...100.
    /// Nil when this response did not contain a usable weekly meter.
    let usedPercent: Double?
    /// True when `creditUsagePercent` was omitted and a confirmed weekly period
    /// with no positive product percent was treated as 0%. proto3 JSON omits
    /// zero-valued scalars; see the parser. This is an assumption.
    let assumedZero: Bool
    let resetsAt: Date?
    let periodType: String?
    let products: [GrokProductUsage]
    /// `config.prepaidBalance.val`, USD cents.
    /// The CLI comment calls this purchased ("bought") credit. claudia and the
    /// grok.com usage panel present that balance as Extra Usage Credits.
    let extraCreditsCents: Int64?
    let onDemandCapCents: Int64?
    let onDemandUsedCents: Int64?
    let isUnifiedBillingUser: Bool?
    /// Usually absent on this HTTP body. The CLI fills it from remote settings
    /// after the request, not from `/billing`. Shown only when the JSON has it.
    let subscriptionTier: String?
    /// Set when `usedPercent` is nil. The popover shows this instead of a bar.
    let unavailableReason: String?
}

/// Decodes the undocumented SuperGrok credits payload.
///
/// Verified from source (xai-org/grok-build `billing.rs`, commit pinned in the
/// README) plus one live capture published by claudia:
///
/// ```json
/// {"config":{
///   "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"...","end":"..."},
///   "creditUsagePercent":100.0,
///   "productUsage":[{"product":"GrokBuild","usagePercent":100.0},{"product":"GrokChat"}],
///   "prepaidBalance":{"val":0},
///   "onDemandCap":{"val":0},"onDemandUsed":{"val":0},
///   "isUnifiedBillingUser":true,
///   "billingPeriodStart":"...","billingPeriodEnd":"..."
/// }}
/// ```
///
/// `creditUsagePercent` is the **used** percent (0 = none consumed). claudia
/// checked this against the CLI panel ("Weekly limit left: 0%" at 100).
///
/// Assumptions, each easy to change in `parse`:
/// - A percent without `currentPeriod.type` is still the weekly pool. The
///   credits endpoint's primary meter is that pool.
/// - `USAGE_PERIOD_TYPE_MONTHLY` (or any other explicit type) is not shown as
///   the weekly bar.
/// - An omitted `creditUsagePercent` plus a weekly period that has `start` and
///   `end`, and no product percent above 0, is treated as 0% used. proto3 JSON
///   omits zero scalars. If a real account omits the field while products
///   report usage, the overall percent stays nil instead of being invented.
/// - `prepaidBalance` is Extra Usage Credits, in USD cents. `val` may be a
///   number (CLI `Cent` is i64) or a string (Management API cents are strings).
///   `{}` means 0, matching the CLI's proto3 comment.
/// - Reset time is `currentPeriod.end`, then `billingPeriodEnd`.
enum GrokBillingParser {
    static let weeklyPeriod = "USAGE_PERIOD_TYPE_WEEKLY"

    static func parse(_ data: Data, now: Date = Date()) -> GrokBillingReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return empty(reason: "The billing response was not JSON.")
        }

        let configObject: Any
        if let rootDict = root as? [String: Any] {
            if let config = rootDict["config"], !(config is NSNull) {
                configObject = config
            } else if rootDict["creditUsagePercent"] != nil || rootDict["currentPeriod"] != nil {
                // Defensive: a bare config object, no wrapper. Not seen in the
                // captured body. The CLI model expects the wrapper.
                configObject = rootDict
            } else {
                return empty(reason: "The billing response had no config object.")
            }
        } else {
            return empty(reason: "The billing response had an unexpected shape.")
        }

        guard let config = configObject as? [String: Any] else {
            return empty(reason: "The billing config was not an object.")
        }

        let period = config["currentPeriod"] as? [String: Any]
        let periodType = period?["type"] as? String
        let periodStart = (period?["start"] as? String).flatMap(DateParsing.parseISO8601)
        let periodEnd = (period?["end"] as? String).flatMap(DateParsing.parseISO8601)
        let billingPeriodEnd = (config["billingPeriodEnd"] as? String).flatMap(DateParsing.parseISO8601)

        let explicitWeekly = periodType == weeklyPeriod
        let explicitOtherPeriod = periodType != nil && periodType != weeklyPeriod
        let confirmedWeeklyWindow = explicitWeekly && periodStart != nil && periodEnd != nil

        let products = parseProducts(config["productUsage"])
        let extra = JSONValues.cents(config["prepaidBalance"])
        let onDemandCap = JSONValues.cents(config["onDemandCap"])
        let onDemandUsed = JSONValues.cents(config["onDemandUsed"])
        let unified = config["isUnifiedBillingUser"] as? Bool
        let tier = nonEmptyString(config["subscriptionTier"])

        let resetsAt: Date?
        if explicitOtherPeriod {
            resetsAt = nil
        } else {
            resetsAt = periodEnd ?? billingPeriodEnd
        }

        func reading(
            usedPercent: Double?,
            assumedZero: Bool,
            reason: String?
        ) -> GrokBillingReading {
            GrokBillingReading(
                usedPercent: usedPercent,
                assumedZero: assumedZero,
                resetsAt: resetsAt,
                periodType: periodType,
                products: products,
                extraCreditsCents: extra,
                onDemandCapCents: onDemandCap,
                onDemandUsedCents: onDemandUsed,
                isUnifiedBillingUser: unified,
                subscriptionTier: tier,
                unavailableReason: reason
            )
        }

        if explicitOtherPeriod {
            return reading(
                usedPercent: nil,
                assumedZero: false,
                reason: "This account reported \(periodType ?? "a non-weekly period"), not the shared weekly pool."
            )
        }

        if let rawPercent = JSONValues.double(config["creditUsagePercent"]) {
            guard let percent = normalizedPercent(rawPercent) else {
                return reading(
                    usedPercent: nil,
                    assumedZero: false,
                    reason: "creditUsagePercent was not a usable percentage."
                )
            }
            return reading(usedPercent: percent, assumedZero: false, reason: nil)
        }

        let productHasUsage = products.contains { ($0.usagePercent ?? 0) > 0 }
        if productHasUsage {
            return reading(
                usedPercent: nil,
                assumedZero: false,
                reason: "The billing response listed product usage but no overall creditUsagePercent."
            )
        }

        if confirmedWeeklyWindow {
            // Assumption: omitted percent + a real weekly window + no product
            // usage means 0% used (proto3 drops zeros). Not a fabricated meter
            // for accounts that simply lack the weekly pool.
            return reading(usedPercent: 0, assumedZero: true, reason: nil)
        }

        _ = now
        return reading(
            usedPercent: nil,
            assumedZero: false,
            reason: "The billing response did not include a weekly usage percent."
        )
    }

    static func displayName(for rawProduct: String) -> String {
        let key = rawProduct
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .uppercased()
        let known: [String: String] = [
            "GROKBUILD": "Grok Build",
            "GROK_BUILD": "Grok Build",
            "PRODUCT_GROK_BUILD": "Grok Build",
            "GROKCHAT": "Grok Chat",
            "GROK_CHAT": "Grok Chat",
            "PRODUCT_GROK_CHAT": "Grok Chat",
            "GROKIMAGINE": "Imagine",
            "GROK_IMAGINE": "Imagine",
            "PRODUCT_GROK_IMAGINE": "Imagine",
            "IMAGINE": "Imagine",
            "GROKVOICE": "Voice",
            "GROK_VOICE": "Voice",
            "PRODUCT_GROK_VOICE": "Voice",
            "VOICE": "Voice",
            "GROKAPI": "API",
            "GROK_API": "API",
            "PRODUCT_GROK_API": "API",
            "API": "API"
        ]
        if let name = known[key] {
            return name
        }

        var text = rawProduct.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.uppercased().hasPrefix("PRODUCT_") {
            text = String(text.dropFirst("PRODUCT_".count))
        }
        text = text.replacingOccurrences(of: "_", with: " ")
        return text.isEmpty ? rawProduct : text
    }

    private static func parseProducts(_ value: Any?) -> [GrokProductUsage] {
        guard let rows = value as? [Any] else { return [] }
        var products: [GrokProductUsage] = []
        for (index, row) in rows.enumerated() {
            guard let object = row as? [String: Any],
                  let raw = nonEmptyString(object["product"]) else {
                continue
            }
            let percent = JSONValues.double(object["usagePercent"]).flatMap(normalizedPercent)
            products.append(
                GrokProductUsage(
                    id: "\(raw)#\(index)",
                    rawProduct: raw,
                    displayName: displayName(for: raw),
                    usagePercent: percent
                )
            )
        }
        return products
    }

    /// Accepts 0...100. Values a hair over 100 (float noise) clamp to 100.
    /// Anything else is unusable — we do not invent a bar from it.
    private static func normalizedPercent(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        if value <= 100 {
            return value
        }
        if value <= 100.5 {
            return 100
        }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func empty(reason: String) -> GrokBillingReading {
        GrokBillingReading(
            usedPercent: nil,
            assumedZero: false,
            resetsAt: nil,
            periodType: nil,
            products: [],
            extraCreditsCents: nil,
            onDemandCapCents: nil,
            onDemandUsedCents: nil,
            isUnifiedBillingUser: nil,
            subscriptionTier: nil,
            unavailableReason: reason
        )
    }
}

enum JSONValues {
    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    /// A billing `Cent`: `{"val": <number|string>}`, `{}` (proto3 zero), or a bare scalar.
    /// Missing / null → nil. Present object without `val` → 0.
    static func cents(_ value: Any?) -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        if let object = value as? [String: Any] {
            if object["val"] == nil || object["val"] is NSNull {
                return 0
            }
            return int64(object["val"])
        }
        return int64(value)
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            return number.int64Value
        case let string as String:
            return Int64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}
