import Foundation

/// Grok Bot spend read from the Cursor Admin or Organization API.
///
/// The published usage-event schema (team and organization
/// `filtered-usage-events`, fetched 2026-10-06) does **not** list
/// `application_type`. Audit logs do, and the values are `grok_bot`,
/// `cursor`, or empty. This parser still reads `application_type` on a usage
/// event when a live response includes it, because that is the only documented
/// token that means Grok Bot. Events without the field are not counted as
/// Grok Bot. `daily-usage-data` has no application split, so it is not used
/// for this bar.
struct CursorGrokBotReading: Equatable {
    /// Sum of `chargedCents` on events whose `application_type` is `grok_bot`.
    /// Nil when events were returned but none carried `application_type`.
    let usedCents: Double?
    /// Denominator in cents. A per-user spend limit from `/teams/spend`, or
    /// the monthly budget typed in Settings.
    let limitCents: Double?
    /// `spend limit` or `monthly budget`. Nil when the bar has no denominator.
    let limitSource: String?
    /// `usedCents / limitCents * 100`. May exceed 100. Nil when either side is missing.
    let usedPercent: Double?
    let resetsAt: Date?
    /// True when `resetsAt` was computed by adding calendar months to
    /// `subscriptionCycleStart`. The spend payload has a start and no end.
    let resetIsAssumedMonthly: Bool
    /// Dollar line under the bar, without a token or email.
    let amountDetail: String?
    let unavailableReason: String?
    /// True when paging stopped before `hasNextPage` cleared.
    let eventsTruncated: Bool
}

enum CursorFetchOutcome: Equatable {
    case notConfigured
    case notModified
    case ready(CursorGrokBotReading)
    case failed(String, retryAfter: TimeInterval?, clearReading: Bool)
}

struct CursorResponseCache: Equatable {
    var spendETag: String?
    var spendBody: Data?
    var eventsETag: String?
    var eventsBody: Data?
}

/// One member row from `POST /teams/spend`.
struct CursorMemberSpend: Equatable {
    let email: String
    let effectivePerUserLimitDollars: Double
    let monthlyLimitDollars: Double?
}

struct CursorSpendSummary: Equatable {
    let members: [CursorMemberSpend]
    let subscriptionCycleStart: Date?
    let totalPages: Int
}

struct CursorUsageEvent: Equatable {
    /// Nil when the key is absent. Empty string when the API sent `""`.
    let applicationType: String?
    let chargedCents: Double
}

struct CursorEventsPage: Equatable {
    let events: [CursorUsageEvent]
    let hasNextPage: Bool
    let sawApplicationTypeKey: Bool
}

enum CursorUsageParser {
    static let grokBotType = "grok_bot"
    static let hourlyInterval: TimeInterval = 60 * 60

    static func isPlausibleAPIKey(_ key: String) -> Bool {
        guard HeaderSafety.isSafe(key), key.hasPrefix("crsr_"), key.count >= 16 else { return false }
        return true
    }

    static func isPlausibleEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HeaderSafety.isSafe(trimmed), trimmed.contains("@"), !trimmed.contains(" ") else { return false }
        return true
    }

    static func isPlausibleOrganizationID(_ id: String) -> Bool {
        guard HeaderSafety.isSafe(id), id.hasPrefix("org_"), id.count >= 5 else { return false }
        return true
    }

    static func parseSpend(_ data: Data) -> CursorSpendSummary? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let rows = root["teamMemberSpend"] as? [Any] ?? []
        let members: [CursorMemberSpend] = rows.compactMap { row in
            guard let object = row as? [String: Any],
                  let email = object["email"] as? String else { return nil }
            return CursorMemberSpend(
                email: email,
                effectivePerUserLimitDollars: JSONValues.double(object["effectivePerUserLimitDollars"]) ?? 0,
                monthlyLimitDollars: JSONValues.double(object["monthlyLimitDollars"])
            )
        }
        let start = epochDate(root["subscriptionCycleStart"])
        let pages = Int(JSONValues.double(root["totalPages"]) ?? 1)
        return CursorSpendSummary(members: members, subscriptionCycleStart: start, totalPages: max(pages, 1))
    }

    /// Organization pool. `contractEndDate` is a documented reset. The pool
    /// limit is not a personal Grok Bot limit, so it is not returned here.
    static func parseContractEnd(_ data: Data) -> Date? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pool = root["pool"] as? [String: Any],
              let raw = pool["contractEndDate"] as? String else { return nil }
        return DateParsing.parseISO8601(raw)
    }

    static func parseEvents(_ data: Data) -> CursorEventsPage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let rows = root["usageEvents"] as? [Any] ?? []
        var sawKey = false
        let events: [CursorUsageEvent] = rows.compactMap { row in
            guard let object = row as? [String: Any] else { return nil }
            let type: String?
            if object.keys.contains("application_type") {
                sawKey = true
                type = object["application_type"] as? String
            } else {
                type = nil
            }
            return CursorUsageEvent(
                applicationType: type,
                chargedCents: JSONValues.double(object["chargedCents"]) ?? 0
            )
        }
        let pagination = root["pagination"] as? [String: Any]
        let hasNext = pagination?["hasNextPage"] as? Bool ?? false
        return CursorEventsPage(events: events, hasNextPage: hasNext, sawApplicationTypeKey: sawKey)
    }

    /// Sums `chargedCents` for `application_type == grok_bot` only.
    /// Returns nil used cents when every event omitted the field.
    static func grokBotCents(in events: [CursorUsageEvent]) -> (cents: Double?, missingType: Int, matched: Int) {
        guard !events.isEmpty else { return (0, 0, 0) }
        var missing = 0
        var matched = 0
        var sum = 0.0
        for event in events {
            guard let type = event.applicationType else {
                missing += 1
                continue
            }
            if type == grokBotType {
                matched += 1
                sum += event.chargedCents
            }
        }
        if missing == events.count {
            return (nil, missing, 0)
        }
        return (sum, missing, matched)
    }

    static func member(matching email: String, in members: [CursorMemberSpend]) -> CursorMemberSpend? {
        let needle = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return members.first { $0.email.lowercased() == needle }
    }

    /// Prefer the documented per-user spend limit. Otherwise the budget the
    /// user typed in Settings. Never invent a limit from team-wide spend.
    static func limitCents(member: CursorMemberSpend?, budgetDollars: Double?) -> (cents: Double?, source: String?) {
        if let member, member.effectivePerUserLimitDollars > 0 {
            return (member.effectivePerUserLimitDollars * 100, "spend limit")
        }
        if let budgetDollars, budgetDollars > 0 {
            return (budgetDollars * 100, "monthly budget")
        }
        return (nil, nil)
    }

    /// `subscriptionCycleStart` has no paired end in the spend payload.
    /// The next UTC calendar-month anniversary is the reset shown on the bar.
    static func assumedMonthlyReset(cycleStart: Date, now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var end = cycleStart
        var guardrail = 0
        while end <= now && guardrail < 240 {
            guard let next = calendar.date(byAdding: .month, value: 1, to: end) else { break }
            end = next
            guardrail += 1
        }
        return end
    }

    static func assemble(
        usedCents: Double?,
        missingTypeEvents: Int,
        eventsSeen: Int,
        truncated: Bool,
        limitCents: Double?,
        limitSource: String?,
        resetsAt: Date?,
        resetIsAssumedMonthly: Bool
    ) -> CursorGrokBotReading {
        let unavailable: String?
        if usedCents == nil && eventsSeen > 0 && missingTypeEvents == eventsSeen {
            unavailable = "Cursor usage events did not include application_type, so Grok Bot spend could not be separated from other Cursor usage."
        } else {
            unavailable = nil
        }

        let percent: Double?
        if let usedCents, let limitCents, limitCents > 0 {
            percent = usedCents / limitCents * 100
        } else {
            percent = nil
        }

        var detail: String?
        if let usedCents {
            if let limitCents, limitCents > 0 {
                detail = "\(USDFormat.cents(Int64(usedCents.rounded()))) of \(USDFormat.cents(Int64(limitCents.rounded())))"
            } else {
                detail = USDFormat.cents(Int64(usedCents.rounded()))
            }
            if truncated {
                detail = (detail ?? "") + " (partial)"
            }
        }

        return CursorGrokBotReading(
            usedCents: usedCents,
            limitCents: limitCents,
            limitSource: limitSource,
            usedPercent: percent,
            resetsAt: resetsAt,
            resetIsAssumedMonthly: resetIsAssumedMonthly,
            amountDetail: detail,
            unavailableReason: unavailable,
            eventsTruncated: truncated
        )
    }

    static func epochDate(_ value: Any?) -> Date? {
        guard let raw = JSONValues.double(value), raw > 0 else { return nil }
        if raw >= 10_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1000)
        }
        return Date(timeIntervalSince1970: raw)
    }
}

struct CursorGrokBotProvider {
    let baseURL: URL
    let apiKey: String
    let memberEmail: String
    let organizationID: String
    let budgetDollars: Double?
    let session: URLSession
    let now: () -> Date

    func fetch(cache: CursorResponseCache) async -> (CursorFetchOutcome, CursorResponseCache) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return (.notConfigured, cache) }
        guard CursorUsageParser.isPlausibleAPIKey(key) else {
            return (.failed(
                "Enter a Cursor API key that starts with crsr_.",
                retryAfter: nil,
                clearReading: true
            ), cache)
        }

        let email = memberEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty && !CursorUsageParser.isPlausibleEmail(email) {
            return (.failed("The member email is not usable.", retryAfter: nil, clearReading: false), cache)
        }
        let org = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !org.isEmpty && !CursorUsageParser.isPlausibleOrganizationID(org) {
            return (.failed(
                "An organization id looks like org_….",
                retryAfter: nil,
                clearReading: false
            ), cache)
        }

        var cache = cache
        let spend: CursorHTTPBody
        do {
            if org.isEmpty {
                spend = try await post(
                    path: "/teams/spend",
                    body: ["page": 1, "pageSize": 100],
                    apiKey: key,
                    etag: cache.spendETag,
                    cached: cache.spendBody
                )
            } else {
                spend = try await post(
                    path: "/organizations/pooled-usage",
                    body: ["organizationId": org],
                    apiKey: key,
                    etag: cache.spendETag,
                    cached: cache.spendBody
                )
            }
        } catch let failure as CursorHTTPFailure {
            return (failure.outcome, cache)
        } catch {
            return (.failed("Could not reach Cursor. Will retry.", retryAfter: nil, clearReading: false), cache)
        }
        if let etag = spend.etag { cache.spendETag = etag }
        if let body = spend.body { cache.spendBody = body }

        let cycleStart: Date?
        let contractEnd: Date?
        let limit: (cents: Double?, source: String?)
        if org.isEmpty {
            guard let summary = spend.body.flatMap(CursorUsageParser.parseSpend) else {
                return (.failed("Cursor spend had an unexpected shape.", retryAfter: nil, clearReading: false), cache)
            }
            cycleStart = summary.subscriptionCycleStart
            contractEnd = nil
            let matched = CursorUsageParser.member(matching: email, in: summary.members)
            if !email.isEmpty && matched == nil && summary.totalPages <= 1 {
                return (.failed(
                    "No team member on this billing cycle matched that email.",
                    retryAfter: nil,
                    clearReading: true
                ), cache)
            }
            limit = CursorUsageParser.limitCents(member: matched, budgetDollars: budgetDollars)
        } else {
            cycleStart = nil
            contractEnd = spend.body.flatMap(CursorUsageParser.parseContractEnd)
            limit = CursorUsageParser.limitCents(member: nil, budgetDollars: budgetDollars)
        }

        let windowStart = cycleStart ?? now().addingTimeInterval(-30 * 24 * 60 * 60)
        let events: CursorHTTPBody
        do {
            var payload: [String: Any] = [
                "startDate": Int(windowStart.timeIntervalSince1970 * 1000),
                "endDate": Int(now().timeIntervalSince1970 * 1000),
                "page": 1,
                "pageSize": 1000
            ]
            if !email.isEmpty { payload["email"] = email }
            if !org.isEmpty { payload["organizationId"] = org }
            let path = org.isEmpty ? "/teams/filtered-usage-events" : "/organizations/filtered-usage-events"
            events = try await post(
                path: path,
                body: payload,
                apiKey: key,
                etag: cache.eventsETag,
                cached: cache.eventsBody
            )
        } catch let failure as CursorHTTPFailure {
            return (failure.outcome, cache)
        } catch {
            return (.failed("Could not reach Cursor. Will retry.", retryAfter: nil, clearReading: false), cache)
        }

        if spend.notModified && events.notModified {
            return (.notModified, cache)
        }
        if let etag = events.etag { cache.eventsETag = etag }
        if let body = events.body { cache.eventsBody = body }

        guard let page = events.body.flatMap(CursorUsageParser.parseEvents) else {
            return (.failed("Cursor usage events had an unexpected shape.", retryAfter: nil, clearReading: false), cache)
        }
        let totals = CursorUsageParser.grokBotCents(in: page.events)
        let resetsAt: Date?
        let assumed: Bool
        if let contractEnd {
            resetsAt = contractEnd
            assumed = false
        } else if let cycleStart {
            resetsAt = CursorUsageParser.assumedMonthlyReset(cycleStart: cycleStart, now: now())
            assumed = true
        } else {
            resetsAt = nil
            assumed = false
        }
        let reading = CursorUsageParser.assemble(
            usedCents: totals.cents,
            missingTypeEvents: totals.missingType,
            eventsSeen: page.events.count,
            truncated: page.hasNextPage,
            limitCents: limit.cents,
            limitSource: limit.source,
            resetsAt: resetsAt,
            resetIsAssumedMonthly: assumed
        )
        return (.ready(reading), cache)
    }

    private struct CursorHTTPBody {
        let body: Data?
        let etag: String?
        let notModified: Bool
    }

    private struct CursorHTTPFailure: Error {
        let outcome: CursorFetchOutcome
    }

    private func post(
        path: String,
        body: [String: Any],
        apiKey: String,
        etag: String?,
        cached: Data?
    ) async throws -> CursorHTTPBody {
        let root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + path) else {
            throw CursorHTTPFailure(outcome: .failed(
                "Could not build the Cursor URL.",
                retryAfter: nil,
                clearReading: false
            ))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let token = Data("\(apiKey):".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CursorHTTPFailure(outcome: .failed(
                "Cursor returned an unexpected response.",
                retryAfter: nil,
                clearReading: false
            ))
        }
        let nextETag = http.value(forHTTPHeaderField: "ETag")
        if http.statusCode == 304, let cached {
            return CursorHTTPBody(body: cached, etag: nextETag ?? etag, notModified: true)
        }
        if http.statusCode == 304 {
            throw CursorHTTPFailure(outcome: .notModified)
        }
        if http.statusCode == 401 {
            throw CursorHTTPFailure(outcome: .failed(
                "Cursor rejected the API key (HTTP 401).",
                retryAfter: nil,
                clearReading: true
            ))
        }
        if http.statusCode == 403 {
            throw CursorHTTPFailure(outcome: .failed(
                "Cursor refused this key (HTTP 403). Grok Bot usage needs a Teams or Enterprise plan and a key with admin or usage scope.",
                retryAfter: nil,
                clearReading: true
            ))
        }
        if http.statusCode == 429 {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
            throw CursorHTTPFailure(outcome: .failed(
                "Cursor rate limited this request. Will retry.",
                retryAfter: retry,
                clearReading: false
            ))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CursorHTTPFailure(outcome: .failed(
                "Cursor request failed (HTTP \(http.statusCode)).",
                retryAfter: nil,
                clearReading: false
            ))
        }
        return CursorHTTPBody(body: data, etag: nextETag, notModified: false)
    }
}
