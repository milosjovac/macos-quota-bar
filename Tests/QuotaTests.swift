import Foundation

@main
struct QuotaTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fixture = """
        {
          "rateLimits": {"primary":{"usedPercent":99}},
          "rateLimitsByLimitId": {
            "codex": {
              "primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1003600},
              "secondary":{"usedPercent":57,"windowDurationMins":10080,"resetsAt":1276480}
            },
            "other":{"primary":{"usedPercent":50}}
          }
        }
        """
        let response = try JSONDecoder().decode(QuotaResponse.self, from: Data(fixture.utf8))
        assert(response.buckets.count == 2)
        let weekly = response.mainBucket!.displayWindow!
        assert(weekly.remaining == 43)
        assert(weekly.durationLabel == "7-day limit")
        assert(weekly.countdown(now: now) == "3.2d")
        assert(!weekly.isExpired(now: now))
        assert(weekly.isExpired(now: Date(timeIntervalSince1970: 1_276_480)))
        assert(weekly.countdown(now: Date(timeIntervalSince1970: 1_276_480)) == "reset pending")
        assert(response.mainBucket!.primary!.countdown(now: now) == "1h")
        let missing = try JSONDecoder().decode(QuotaResponse.self, from: Data("{\"rateLimits\":{\"primary\":{}}}".utf8))
        assert(missing.mainBucket?.displayWindow?.remaining == nil)
        assert(missing.mainBucket?.displayWindow?.countdown(now: now) == "reset unknown")
        assert(QuotaWindow(usedPercent: 110, windowDurationMins: nil, resetsAt: nil).remaining == 0)
        assert(QuotaWindow(usedPercent: -10, windowDurationMins: nil, resetsAt: nil).remaining == 100)
        assert(QuotaWindow(usedPercent: 99.9, windowDurationMins: nil, resetsAt: nil).remaining == 0)
        assert(QuotaWindow(usedPercent: 0, windowDurationMins: nil, resetsAt: 1_000_030).countdown(now: now) == "1m")
        let fallback = try JSONDecoder().decode(QuotaResponse.self, from: Data("{\"rateLimitsByLimitId\":{},\"rateLimits\":{\"primary\":{\"usedPercent\":25}}}".utf8))
        assert(fallback.mainBucket?.displayWindow?.remaining == 75)
        print("Quota tests passed: bucket selection, remaining percentages, missing data, countdowns and reset boundaries.")
    }
}
