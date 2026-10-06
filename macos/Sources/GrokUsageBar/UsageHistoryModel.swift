import Foundation

struct UsageDataPoint: Codable, Identifiable {
    var id: UUID
    let timestamp: Date
    /// Weekly pool used fraction, 0...1.
    let pctWeekly: Double
    /// Grok Bot used fraction, 0...1. Nil when that source had no percent.
    let pctBot: Double?
    /// False when this point has no weekly sample. `pctWeekly` is then unused.
    let includesWeekly: Bool
    /// Cursor Models used fraction, 0...1. Recorded when that pool is the bottom slot.
    let pctCursorModels: Double?

    init(
        timestamp: Date = Date(),
        pctWeekly: Double,
        pctBot: Double? = nil,
        includesWeekly: Bool = true,
        pctCursorModels: Double? = nil
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.pctWeekly = pctWeekly
        self.pctBot = pctBot
        self.includesWeekly = includesWeekly
        self.pctCursorModels = pctCursorModels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        if let weekly = try container.decodeIfPresent(Double.self, forKey: .pctWeekly) {
            pctWeekly = weekly
        } else if let legacy = try container.decodeIfPresent(Double.self, forKey: .pct7d) {
            // Older points from this fork's first schema used the 7-day field
            // name. The config directory is new, so this is only a safety net.
            pctWeekly = legacy
        } else {
            pctWeekly = 0
        }
        pctBot = try container.decodeIfPresent(Double.self, forKey: .pctBot)
        includesWeekly = try container.decodeIfPresent(Bool.self, forKey: .includesWeekly) ?? true
        pctCursorModels = try container.decodeIfPresent(Double.self, forKey: .pctCursorModels)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(pctWeekly, forKey: .pctWeekly)
        try container.encodeIfPresent(pctBot, forKey: .pctBot)
        try container.encode(includesWeekly, forKey: .includesWeekly)
        try container.encodeIfPresent(pctCursorModels, forKey: .pctCursorModels)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case pctWeekly
        case pctBot
        case pct7d
        case includesWeekly
        case pctCursorModels
    }
}

struct UsageHistory: Codable {
    var dataPoints: [UsageDataPoint] = []
}

enum TimeRange: String, CaseIterable, Identifiable {
    case hour1 = "1h"
    case hour6 = "6h"
    case day1 = "1d"
    case day7 = "7d"
    case day30 = "30d"

    var id: String { rawValue }

    var interval: TimeInterval {
        switch self {
        case .hour1: return 3600
        case .hour6: return 6 * 3600
        case .day1: return 86400
        case .day7: return 7 * 86400
        case .day30: return 30 * 86400
        }
    }

    var targetPointCount: Int {
        switch self {
        case .hour1: return 120
        case .hour6: return 180
        case .day1: return 200
        case .day7: return 200
        case .day30: return 200
        }
    }
}
