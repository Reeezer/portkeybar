import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let client = PortkeyClient()
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var usage: Usage?
    private var lastUpdated: Date?
    private var refreshError: String?
    private var startupError: String?
    private var period = UsagePeriod.saved()
    private var user: String { UserDefaults.standard.string(forKey: "user") ?? NSUserName() }

    func applicationDidFinishLaunching(_: Notification) {
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        item.menu = menu
        if UserDefaults.standard.object(forKey: "launchAtLogin") == nil {
            setLaunchAtLogin(true)
        }
        timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 15
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil
        )
        refresh()
    }

    @objc private func refresh() {
        guard refreshTask == nil else { return }
        let currentUser = user
        let currentPeriod = period
        refreshTask = Task {
            defer {
                let restart = Task.isCancelled
                refreshTask = nil
                updateMenu()
                if restart { refresh() }
            }
            do {
                let key = try Credentials.read()
                let now = Date()
                let newUsage = try await client.fetch(key: key, user: currentUser, period: currentPeriod, now: now)
                guard !Task.isCancelled else { return }
                usage = newUsage
                lastUpdated = now
                refreshError = nil
            } catch {
                guard !Task.isCancelled else { return }
                refreshError = error.localizedDescription
            }
        }
        updateMenu()
    }

    private func updateMenu() {
        item.button?.title = (usage?.title ?? "Portkey …") + (refreshError == nil ? "" : " ⚠")
        let updated = lastUpdated.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "No usage fetched yet"
        let details = "\(period.rawValue) · \(user)\nHighest spend ranks #1\n\(updated)"
        item.button?.toolTip = details + (refreshError.map { "\n\($0)" } ?? "")
        item.button?.setAccessibilityLabel("Portkey cost and team spending rank · \(period.rawValue)")
        item.button?.setAccessibilityValue(item.button?.title)
        menu.removeAllItems()
        addItem("\(period.rawValue) · \(user)")
        addItem("Highest spend ranks #1")
        addItem(updated)
        if let refreshError { addItem(refreshError) }
        if let startupError { addItem(startupError) }
        menu.addItem(.separator())
        let periods = NSMenu(title: "Time range")
        for choice in UsagePeriod.allCases {
            let entry = NSMenuItem(title: choice.rawValue, action: #selector(selectPeriod(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.rawValue
            entry.state = choice == period ? .on : .off
            periods.addItem(entry)
        }
        addItem("Time range").submenu = periods
        let refreshItem = addItem(refreshTask == nil ? "Refresh now" : "Refreshing…", action: #selector(refresh))
        refreshItem.isEnabled = refreshTask == nil
        addItem("Open Portkey", action: #selector(openPortkey))
        addItem("Settings…", action: #selector(settings))
        let login = addItem("Launch at login", action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if SMAppService.mainApp.status == .requiresApproval {
            addItem("Allow launch in System Settings…", action: #selector(openLoginSettings))
        }
        menu.addItem(.separator())
        addItem("Quit PortkeyBar", action: #selector(quit), key: "q")
    }

    @objc private func selectPeriod(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let choice = UsagePeriod(rawValue: value), choice != period else { return }
        period = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "timeRange")
        reloadUsage()
    }

    private func reloadUsage() {
        usage = nil
        lastUpdated = nil
        refreshError = nil
        if let refreshTask {
            refreshTask.cancel()
            updateMenu()
        } else { refresh() }
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector? = nil, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    @objc private func openPortkey() {
        NSWorkspace.shared.open(URL(string: "https://app.portkey.ai")!)
    }

    @objc private func settings() {
        let alert = NSAlert()
        alert.messageText = "PortkeyBar settings"
        alert.informativeText = "Use an API key from your team's workspace with analytics access. Leave the key empty to keep the saved key."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let userField = NSTextField(string: user)
        userField.placeholderString = "Portkey User ID"
        userField.setAccessibilityLabel("Portkey User ID")
        let keyField = NSSecureTextField()
        keyField.placeholderString = "Portkey API key"
        keyField.setAccessibilityLabel("Portkey API key")
        let fields = NSStackView(views: [NSTextField(labelWithString: "User ID"), userField,
                                         NSTextField(labelWithString: "API key (saved in Keychain)"), keyField])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 360, height: 110)
        userField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        keyField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        alert.accessoryView = fields
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newUser = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newUser.isEmpty else { showError("Enter your Portkey User ID."); return }
        do {
            if !keyField.stringValue.isEmpty { try Credentials.save(keyField.stringValue) }
            _ = try Credentials.read()
            UserDefaults.standard.set(newUser, forKey: "user")
            reloadUsage()
        } catch { showError(error.localizedDescription) }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not save settings"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func toggleLogin() {
        setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
        updateMenu()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
            startupError = nil
        } catch { startupError = "Launch at login: \(error.localizedDescription)" }
    }

    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func quit() { NSApp.terminate(nil) }
}
