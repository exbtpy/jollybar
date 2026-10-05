import Foundation

struct UsageDataPoint: Codable, Identifiable {
    var id: UUID
    let timestamp: Date
    /// Weekly pool used fraction, 0...1.
    let pctWeekly: Double

    init(timestamp: Date = Date(), pctWeekly: Double) {
        self.id = UUID()
        self.timestamp = timestamp
        self.pctWeekly = pctWeekly
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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(pctWeekly, forKey: .pctWeekly)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case pctWeekly
        case pct7d
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
