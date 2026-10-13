import Foundation

enum AITool: String, CaseIterable {
    case codex, claude
    var name: String { self == .codex ? "Codex" : "Claude" }
    var icon: String { self == .codex ? "OpenAI" : "Claude" }

    static func detect() -> [AITool] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"]
        return allCases.filter { tool in
            let apps = tool == .codex ? ["Codex", "ChatGPT"] : ["Claude"]
            let appFound = apps.contains { app in
                ["/Applications", home + "/Applications"].contains { fm.fileExists(atPath: $0 + "/" + app + ".app") }
            }
            let cliFound = tool == .codex ? (try? CodexClient.executable()) != nil
                : paths.contains { fm.isExecutableFile(atPath: $0 + "/claude") }
            return appFound || cliFound
        }
    }
}

enum DisplayMode: String { case all, rotating }

struct DisplaySelection {
    var selected: Set<AITool>
    var mode: DisplayMode
    var rotationStart: TimeInterval

    func visible(installed: [AITool], uptime: TimeInterval) -> [AITool] {
        let tools = installed.filter { selected.contains($0) }
        guard mode == .rotating, !tools.isEmpty else { return tools }
        let index = Int(max(0, uptime - rotationStart) / 10) % tools.count
        return [tools[index]]
    }
}

final class ToolState {
    var response: QuotaResponse?
    var error: String?
    var refreshing = false
    var updatedAt: Date?
    var lastAttempt = Date.distantPast
    var nextAllowedRefresh = Date.distantPast

    func title(now: Date) -> String {
        guard error == nil else { return "— !" }
        guard let window = response?.mainBucket?.displayWindow else { return "—" }
        guard !window.isExpired(now: now) else { return "↻" }
        return "\(window.remaining.map { "\($0)%" } ?? "—") · \(window.countdown(now: now))"
    }
}

final class QuotaStore {
    var installed = [AITool]()
    let states = Dictionary(uniqueKeysWithValues: AITool.allCases.map { ($0, ToolState()) })
    var selection: DisplaySelection
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private var timer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: "selectedTools") ?? [AITool.codex.rawValue]
        selection = DisplaySelection(selected: Set(saved.compactMap(AITool.init)),
            mode: DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "all") ?? .all,
            rotationStart: ProcessInfo.processInfo.systemUptime)
    }

    var visible: [AITool] { selection.visible(installed: installed, uptime: ProcessInfo.processInfo.systemUptime) }

    func start() {
        detect()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.onChange?()
            for tool in self.installed {
                let state = self.states[tool]!
                let expired = state.response?.mainBucket?.displayWindow?.isExpired() ?? false
                let interval: TimeInterval = state.error == nil && expired ? 60 : 300
                if Date().timeIntervalSince(state.lastAttempt) >= interval { self.refresh(tool) }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func detect() {
        installed = AITool.detect()
        selection.rotationStart = ProcessInfo.processInfo.systemUptime
        onChange?()
        refreshAll()
    }

    func toggle(_ tool: AITool) {
        if selection.selected.contains(tool) { selection.selected.remove(tool) }
        else { selection.selected.insert(tool) }
        saveSelection()
    }

    func setMode(_ mode: DisplayMode) {
        selection.mode = mode
        saveSelection()
    }

    private func saveSelection() {
        selection.rotationStart = ProcessInfo.processInfo.systemUptime
        defaults.set(AITool.allCases.filter { selection.selected.contains($0) }.map(\.rawValue), forKey: "selectedTools")
        defaults.set(selection.mode.rawValue, forKey: "displayMode")
        onChange?()
    }

    func refreshAll() { installed.forEach { refresh($0) } }

    func refresh(_ tool: AITool, allowPrompt: Bool = false, completion: ((Result<QuotaResponse, Error>) -> Void)? = nil) {
        let state = states[tool]!
        guard !state.refreshing else {
            completion?(.failure(QuotaError(message: "A usage check is already running. Wait for it to finish, then try again.")))
            return
        }
        guard Date() >= state.nextAllowedRefresh else {
            completion?(.failure(QuotaError(message: "Claude requested a pause in usage checks. Try again after " + state.nextAllowedRefresh.formatted(date: .omitted, time: .standard) + ".")))
            return
        }
        state.refreshing = true
        state.lastAttempt = Date()
        onChange?()
        Task.detached {
            let result: Result<QuotaResponse, Error>
            do {
                if tool == .codex { result = .success(try CodexClient.fetch()) }
                else { result = .success(try await ClaudeClient.fetch(allowPrompt: allowPrompt)) }
            } catch { result = .failure(error) }
            await MainActor.run {
                state.refreshing = false
                switch result {
                case .success(let response):
                    state.response = response
                    state.updatedAt = Date()
                    state.error = nil
                case .failure(let error):
                    state.error = error.localizedDescription
                    if let interval = (error as? QuotaError)?.retryAfter {
                        state.nextAllowedRefresh = Date().addingTimeInterval(interval)
                    }
                }
                self.onChange?()
                completion?(result)
            }
        }
    }
}
