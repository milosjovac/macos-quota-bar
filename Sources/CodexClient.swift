import Foundation
import Darwin

struct QuotaError: LocalizedError {
    let message: String
    let retryAfter: TimeInterval?
    init(message: String, retryAfter: TimeInterval? = nil) {
        self.message = message
        self.retryAfter = retryAfter
    }
    var errorDescription: String? { message }
}

struct CodexClient {
    static func executable() throws -> String {
        let defaults = UserDefaults.standard.string(forKey: "codexPath")
        let candidates = [defaults, ProcessInfo.processInfo.environment["CODEX_BINARY"],
                          "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          NSHomeDirectory() + "/.local/bin/codex",
                          "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                          "/Applications/Codex.app/Contents/Resources/codex"]
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { String($0) + "/codex" }
        for path in candidates.compactMap({ $0 }) + pathCandidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw QuotaError(message: "Codex CLI not found. Install Codex, then choose its executable below.")
    }

    static func fetch() throws -> QuotaResponse {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: try executable())
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let stopDeadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "codex_quota_bar", "title": "Codex Quota", "version": "1.0.0"]
        ]])
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        let fd = output.fileHandleForReading.fileDescriptor
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                throw QuotaError(message: "Could not read from Codex. Try refreshing.")
            }
            guard ready > 0 else { continue }
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { throw QuotaError(message: "Codex stopped before returning usage. Check your Codex CLI installation and sign-in.") }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count < 4_000_000 else { throw QuotaError(message: "Codex returned an oversized response.") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int, id == 1 || id == 2 else { continue }
                if let error = message["error"] as? [String: Any] {
                    throw QuotaError(message: (error["message"] as? String ?? "Codex could not read usage.") + " Sign in with ChatGPT using codex login, then refresh.")
                }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if let result = message["result"] {
                    let data = try JSONSerialization.data(withJSONObject: result)
                    return try JSONDecoder().decode(QuotaResponse.self, from: data)
                }
            }
        }
        throw QuotaError(message: "Codex took too long to respond. Check your connection and refresh.")
    }
}
