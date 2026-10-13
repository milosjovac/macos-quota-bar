import Foundation

struct QuotaWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?

    var remaining: Int? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return Int(max(0, min(100, 100 - usedPercent)).rounded(.down))
    }

    var durationLabel: String {
        guard let minutes = windowDurationMins else { return "Quota window" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day limit" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour limit" }
        return "\(minutes)-minute limit"
    }

    func countdown(now: Date = Date()) -> String {
        guard let resetsAt else { return "reset unknown" }
        let seconds = resetsAt - now.timeIntervalSince1970
        guard seconds > 0 else { return "reset pending" }
        if seconds >= 86400 { return String(format: "%.1fd", seconds / 86400) }
        if seconds >= 3600 { return "\(Int(ceil(seconds / 3600)))h" }
        return "\(max(1, Int(ceil(seconds / 60))))m"
    }

    func isExpired(now: Date = Date()) -> Bool {
        resetsAt.map { $0 <= now.timeIntervalSince1970 } ?? false
    }
}

struct QuotaBucket: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?

    var windows: [QuotaWindow] { [primary, secondary].compactMap { $0 } }
    var displayWindow: QuotaWindow? {
        windows.max { ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0) }
    }
}

struct QuotaResponse: Decodable {
    let rateLimits: QuotaBucket?
    let rateLimitsByLimitId: [String: QuotaBucket]?

    var buckets: [(id: String, bucket: QuotaBucket)] {
        if let map = rateLimitsByLimitId, !map.isEmpty {
            return map.keys.sorted().compactMap { key in map[key].map { (key, $0) } }
        }
        return rateLimits.map { [($0.limitId ?? "codex", $0)] } ?? []
    }

    var mainBucket: QuotaBucket? {
        buckets.first(where: { $0.id == "codex" })?.bucket ?? buckets.first?.bucket
    }
}
