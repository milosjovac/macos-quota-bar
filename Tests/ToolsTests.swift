import Foundation

@main
struct ToolsTests {
    static func main() throws {
        let installed: [AITool] = [.codex, .claude]
        var selection = DisplaySelection(selected: [.codex, .claude], mode: .rotating, rotationStart: 100)
        assert(selection.visible(installed: installed, uptime: 100) == [.codex])
        assert(selection.visible(installed: installed, uptime: 109.99) == [.codex])
        assert(selection.visible(installed: installed, uptime: 110) == [.claude])
        assert(selection.visible(installed: installed, uptime: 120) == [.codex])
        assert(selection.visible(installed: [.claude], uptime: 120) == [.claude])
        selection.mode = .all
        assert(selection.visible(installed: installed, uptime: 111) == installed)
        selection.selected = []
        assert(selection.visible(installed: installed, uptime: 111).isEmpty)
        selection.mode = .rotating
        assert(selection.visible(installed: installed, uptime: 111).isEmpty)

        let suite = "QuotaTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuotaStore(defaults: defaults)
        assert(store.selection.selected == [.codex])
        store.toggle(.claude)
        store.setMode(.rotating)
        let restored = QuotaStore(defaults: defaults)
        assert(restored.selection.selected == [.codex, .claude])
        assert(restored.selection.mode == .rotating)
        store.toggle(.codex)
        store.toggle(.claude)
        assert(QuotaStore(defaults: defaults).selection.selected.isEmpty)

        let fixture = """
        {"five_hour":{"utilization":20,"resets_at":null},
        "seven_day":{"utilization":37,"resets_at":"2030-01-01T00:00:00.000Z"},
        "seven_day_opus":{"utilization":70,"resets_at":"2030-01-01T00:00:00Z"}}
        """
        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: Data(fixture.utf8))
        assert(usage.response.mainBucket?.displayWindow?.remaining == 63)
        assert(usage.response.mainBucket?.primary?.resetsAt == nil)
        assert(usage.response.mainBucket?.secondary?.resetsAt == 1_893_456_000)
        assert(usage.response.buckets.count == 2)
        let missing = try JSONDecoder().decode(ClaudeUsage.self, from: Data("{}".utf8))
        assert(missing.response.mainBucket?.displayWindow == nil)

        let now = Date(timeIntervalSince1970: 100)
        let key = "acct:A|client:org:https://api.anthropic.com:user:profile user:inference"
        let cache: [String: Any] = [key: ["token": "test-only", "expiresAt": 200_000.0]]
        let token = try ClaudeCredentials.desktopToken(cache: cache, account: "A", now: now)
        assert(token == "test-only")
        for account in ["B", "A-suffix", ""] {
            do {
                _ = try ClaudeCredentials.desktopToken(cache: cache, account: account.isEmpty ? nil : account, now: now)
                assertionFailure("Must reject absent or different active account")
            } catch {}
        }
        do {
            _ = try ClaudeCredentials.desktopToken(cache: cache, account: "A", now: Date(timeIntervalSince1970: 201))
            assertionFailure("Must reject expired credentials")
        } catch {}
        let cacheStore = KeychainCredentialCache()
        var reads = 0
        let firstRead = cacheStore.read(service: "desktop") { reads += 1; return Data("test-key".utf8) }
        let secondRead = try cacheStore.read(service: "desktop") { () throws -> Data in
            reads += 1
            throw QuotaError(message: "One-time permission is no longer available")
        }
        assert(firstRead == secondRead && reads == 1)
        do {
            _ = try cacheStore.read(service: "missing") { () throws -> Data in throw QuotaError(message: "Denied") }
            assertionFailure("Denied reads must fail")
        } catch {}
        let retried = cacheStore.read(service: "missing") { Data("approved".utf8) }
        assert(retried == Data("approved".utf8))
        let state = ToolState()
        state.response = usage.response
        state.error = "offline"
        assert(state.title(now: now) == "— !")
        print("Tool tests passed: detection selection, persistence, 10-second rotation, Claude parsing, account isolation, one-time Keychain access and stale errors.")
    }
}
