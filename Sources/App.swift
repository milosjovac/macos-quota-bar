import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = QuotaStore()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var logos = [AITool: NSImage]()
    private let logoSize: CGFloat = 14

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        for tool in AITool.allCases {
            if let url = Bundle.main.url(forResource: tool.icon, withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: logoSize, height: logoSize)
                image.isTemplate = false
                logos[tool] = image
            }
        }
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        store.onChange = { [weak self] in self?.updateTitle() }
        updateTitle()
        store.start()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let font = button.font ?? NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()
        let tools = store.visible
        for (index, tool) in tools.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "   ·   ")) }
            if let logo = logos[tool] {
                let attachment = NSTextAttachment()
                attachment.image = logo
                attachment.bounds = NSRect(x: 0, y: (font.capHeight - logoSize) / 2, width: logoSize, height: logoSize)
                title.append(NSAttributedString(attachment: attachment))
                title.append(NSAttributedString(string: " "))
            } else {
                title.append(NSAttributedString(string: tool.name + " "))
            }
            title.append(NSAttributedString(string: store.states[tool]!.title(now: Date())))
        }
        if tools.isEmpty { title.append(NSAttributedString(string: "AI Quota")) }
        title.addAttribute(.font, value: font, range: NSRange(location: 0, length: title.length))
        if button.attributedTitle != title { button.attributedTitle = title }
        let description = tools.map { "\($0.name): \(store.states[$0]!.title(now: Date()))" }.joined(separator: "; ")
        button.toolTip = description.isEmpty ? "Select tools in the menu" : description
        button.setAccessibilityLabel(description.isEmpty ? "AI Quota" : description)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addInfo("AI Quota")
        addAction("Detect Installed AI Tools", action: #selector(detectTools))
        if store.installed.isEmpty { addInfo("No supported tools found (Codex or Claude)") }
        menu.addItem(.separator())
        for tool in store.installed {
            let item = NSMenuItem(title: tool.name, action: nil, keyEquivalent: "")
            item.submenu = toolMenu(tool)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = addAction("Show All Selected Quotas", action: #selector(showAll))
        all.state = store.selection.mode == .all ? .on : .off
        let rotate = addAction("Rotate Selected Quotas Every 10 Seconds", action: #selector(rotateTools))
        rotate.state = store.selection.mode == .rotating ? .on : .off
        menu.addItem(.separator())
        let busy = store.installed.contains { store.states[$0]!.refreshing }
        let refresh = addAction(busy ? "Refreshing…" : "Refresh All", action: #selector(refreshQuota))
        refresh.isEnabled = !busy && !store.installed.isEmpty
        if !store.installed.contains(.codex) { addAction("Choose Codex CLI…", action: #selector(chooseCLI)) }
        addAction("Quit AI Quota", action: #selector(quit), key: "q")
    }

    private func toolMenu(_ tool: AITool) -> NSMenu {
        let submenu = NSMenu(title: tool.name)
        submenu.autoenablesItems = false
        let state = store.states[tool]!
        let toggle = addAction("Show in Menu Bar", action: #selector(toggleTool(_:)), to: submenu)
        toggle.representedObject = tool.rawValue
        toggle.state = store.selection.selected.contains(tool) ? .on : .off
        submenu.addItem(.separator())
        if state.error != nil {
            addInfo("Usage unavailable", to: submenu)
            let error = addAction("Show Connection Details…", action: #selector(showError(_:)), to: submenu)
            error.representedObject = tool.rawValue
            if state.response != nil { addInfo("Last known usage (may be outdated)", to: submenu) }
        }
        if let response = state.response {
            for entry in response.buckets {
                if response.buckets.count > 1 { addInfo(entry.bucket.limitName ?? entry.id, to: submenu) }
                for window in entry.bucket.windows {
                    let remaining = window.remaining.map { "\($0)% remaining" } ?? "Usage unavailable"
                    addInfo("\(window.durationLabel): \(remaining)", to: submenu)
                    if let reset = window.resetsAt {
                        addInfo(window.isExpired() ? "Reset pending" : "Resets in \(window.countdown())", to: submenu)
                        addInfo(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened), to: submenu)
                    } else { addInfo("Reset time unavailable", to: submenu) }
                }
            }
            if response.buckets.allSatisfy({ $0.bucket.windows.isEmpty }) { addInfo("No quota windows available", to: submenu) }
        } else if state.refreshing { addInfo("Fetching usage…", to: submenu) }
        if let date = state.updatedAt {
            addInfo("Updated \(date.formatted(date: .omitted, time: .shortened))", to: submenu)
        }
        if tool == .claude {
            let connect = addAction("Connect Claude…", action: #selector(connectClaude), to: submenu)
            connect.isEnabled = !state.refreshing
            addAction("Open Claude", action: #selector(openClaude), to: submenu)
        }
        if tool == .codex {
            submenu.addItem(.separator())
            addAction("Choose Codex CLI…", action: #selector(chooseCLI), to: submenu)
        }
        return submenu
    }

    private func addInfo(_ title: String, to destination: NSMenu? = nil) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        (destination ?? menu).addItem(item)
    }

    @discardableResult
    private func addAction(_ title: String, action: Selector, key: String = "", to destination: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        (destination ?? menu).addItem(item)
        return item
    }

    @objc private func wake() { store.refreshAll() }
    @objc private func refreshQuota() { store.refreshAll() }
    @objc private func detectTools() { store.detect() }
    @objc private func showAll() { store.setMode(.all) }
    @objc private func rotateTools() { store.setMode(.rotating) }
    @objc private func connectClaude() {
        NSApp.activate(ignoringOtherApps: true)
        store.refresh(.claude, allowPrompt: true) { result in
            let alert = NSAlert()
            switch result {
            case .success(let response):
                alert.messageText = "Claude connected"
                if let window = response.mainBucket?.displayWindow {
                    let remaining = window.remaining.map { "\($0)%" } ?? "Unknown amount"
                    alert.informativeText = "\(remaining) remaining · reset in \(window.countdown())."
                } else {
                    alert.informativeText = "Connected, but Claude has not provided any quota windows yet."
                }
                alert.alertStyle = .informational
            case .failure(let error):
                alert.messageText = "Couldn’t connect Claude"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
            }
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    @objc private func openClaude() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
    }
    @objc private func toggleTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tool = AITool(rawValue: raw) else { return }
        store.toggle(tool)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showError(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tool = AITool(rawValue: raw) else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn’t refresh " + tool.name + " quota"
        alert.informativeText = store.states[tool]?.error ?? "Try refreshing again."
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.title = "Choose the codex executable"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.isExecutableFile(atPath: url.path) else { return }
            UserDefaults.standard.set(url.path, forKey: "codexPath")
            store.detect()
        }
    }
}

@main
struct CodexQuotaApp {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--detect") {
            print(AITool.detect().map(\.name).joined(separator: "\n"))
            return
        }
        if CommandLine.arguments.contains("--check") {
            let tools = CommandLine.arguments.contains("--all") ? AITool.detect() : [.codex]
            Task.detached {
                var failed = false
                for tool in tools {
                    do {
                        let response: QuotaResponse
                        if tool == .codex { response = try CodexClient.fetch() }
                        else { response = try await ClaudeClient.fetch() }
                        for entry in response.buckets {
                            for window in entry.bucket.windows {
                                print("\(tool.name) / \(entry.id): \(window.remaining.map { "\($0)%" } ?? "unknown") remaining; reset in \(window.countdown())")
                            }
                        }
                        if response.buckets.isEmpty { print("\(tool.name): no quota windows available.") }
                    } catch {
                        fputs("\(tool.name): \(error.localizedDescription)\n", stderr)
                        failed = true
                    }
                }
                exit(failed ? 1 : 0)
            }
            dispatchMain()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
