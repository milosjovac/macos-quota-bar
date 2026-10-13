import Foundation
import Security
import CommonCrypto

struct ClaudeUsage: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?

        func quota(minutes: Int) -> QuotaWindow {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = resets_at.flatMap { formatter.date(from: $0) }
            formatter.formatOptions = [.withInternetDateTime]
            let reset = fractional ?? resets_at.flatMap { formatter.date(from: $0) }
            return QuotaWindow(usedPercent: utilization, windowDurationMins: minutes, resetsAt: reset?.timeIntervalSince1970)
        }
    }
    let five_hour: Window?
    let seven_day: Window?
    let seven_day_sonnet: Window?
    let seven_day_opus: Window?

    var response: QuotaResponse {
        var buckets = ["claude": QuotaBucket(limitId: "claude", limitName: "Claude",
            primary: five_hour?.quota(minutes: 300), secondary: seven_day?.quota(minutes: 10080))]
        if let seven_day_sonnet {
            buckets["sonnet"] = QuotaBucket(limitId: "sonnet", limitName: "Sonnet", primary: seven_day_sonnet.quota(minutes: 10080), secondary: nil)
        }
        if let seven_day_opus {
            buckets["opus"] = QuotaBucket(limitId: "opus", limitName: "Opus", primary: seven_day_opus.quota(minutes: 10080), secondary: nil)
        }
        return QuotaResponse(rateLimits: buckets["claude"], rateLimitsByLimitId: buckets)
    }
}

final class KeychainCredentialCache {
    private let lock = NSLock()
    private var values = [String: Data]()

    func read(service: String, load: () throws -> Data) rethrows -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let value = values[service] { return value }
        let value = try load()
        values[service] = value
        return value
    }
}

struct ClaudeCredentials {
    private static let desktopKey = KeychainCredentialCache()

    static func keychain(service: String, allowPrompt: Bool) throws -> Data {
        var result: CFTypeRef?
        // Claude uses the legacy file-based login keychain, which ignores LAContext's no-UI flag.
        var previousInteraction: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&previousInteraction)
        SecKeychainSetUserInteractionAllowed(allowPrompt)
        defer { SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            throw QuotaError(message: "Cannot read \(service) from Keychain (\(status)): \(reason). Choose Connect Claude to allow access. If the item is missing, sign in to Claude and open its Code tab first.")
        }
        return data
    }

    static func token(allowPrompt: Bool) throws -> String {
        let config = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Claude/config.json")
        if FileManager.default.fileExists(atPath: config.path) {
            let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any] ?? [:]
            if let encoded = settings["oauth:tokenCacheV2"] as? String,
               let encrypted = Data(base64Encoded: encoded), encrypted.starts(with: Data("v10".utf8)) {
                let password = try desktopKey.read(service: "Claude Safe Storage") {
                    try keychain(service: "Claude Safe Storage", allowPrompt: allowPrompt)
                }
                let decrypted = try decrypt(encrypted, password: password)
                let cache = try JSONSerialization.jsonObject(with: decrypted) as? [String: Any] ?? [:]
                return try desktopToken(cache: cache, account: settings["lastKnownAccountUuid"] as? String)
            }
        }
        let path = (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude") + "/.credentials.json"
        let data: Data
        if FileManager.default.fileExists(atPath: path) {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            data = try keychain(service: "Claude Code-credentials", allowPrompt: allowPrompt)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let oauth = object?["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw QuotaError(message: "Sign in to Claude Code with a Claude subscription, then refresh.")
        }
        if let expiry = oauth["expiresAt"] as? Double, expiry / 1000 <= Date().timeIntervalSince1970 {
            throw QuotaError(message: "Claude’s sign-in has expired. Open Claude or Claude Code to renew it, then refresh.")
        }
        return token
    }

    static func desktopToken(cache: [String: Any], account: String?, now: Date = Date()) throws -> String {
        let candidates = cache.sorted { $0.key < $1.key }.compactMap { key, value -> (String, Double)? in
            guard let entry = value as? [String: Any],
                  let token = entry["token"] as? String, !token.isEmpty,
                  let expires = entry["expiresAt"] as? Double, expires / 1000 > now.timeIntervalSince1970,
                  key.contains(":https://api.anthropic.com:"), key.contains("user:profile"),
                  key.contains("user:inference"),
                  account.map({ !$0.isEmpty && key.hasPrefix("acct:" + $0 + "|") }) == true else { return nil }
            return (token, expires)
        }
        guard let token = candidates.max(by: { $0.1 < $1.1 })?.0 else {
            throw QuotaError(message: "Open Claude’s Code tab to refresh its sign-in, then try again. No current Claude usage credential was found for the active account.")
        }
        return token
    }

    static func decrypt(_ encrypted: Data, password: Data) throws -> Data {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derived = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.bindMemory(to: Int8.self).baseAddress,
                password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { throw QuotaError(message: "Could not unlock Claude credentials.") }
        let ciphertext = Data(encrypted.dropFirst(3))
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var count = 0
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        let status = ciphertext.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key, key.count, iv, bytes.baseAddress, ciphertext.count, &output, output.count, &count)
        }
        guard status == kCCSuccess else { throw QuotaError(message: "Claude’s credential storage format could not be read. Sign in again in Claude and retry.") }
        return Data(output.prefix(count))
    }
}

struct ClaudeClient {
    static func fetch(allowPrompt: Bool = false) async throws -> QuotaResponse {
        let token = try ClaudeCredentials.token(allowPrompt: allowPrompt)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 25
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QuotaError(message: "Claude returned an invalid response.") }
        switch http.statusCode {
        case 200: return try JSONDecoder().decode(ClaudeUsage.self, from: data).response
        case 401, 403: throw QuotaError(message: "Claude’s session needs renewal. Open Claude’s Code tab or sign in to Claude Code, then refresh.")
        case 429:
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 300
            throw QuotaError(message: "Claude is limiting usage checks. Please wait a few minutes before refreshing.", retryAfter: max(300, seconds))
        default: throw QuotaError(message: "Claude usage is unavailable (HTTP \(http.statusCode)). Try again later.")
        }
    }
}
