import AppKit
import ServiceManagement

if CommandLine.arguments.contains("--configure-from-env") {
    do {
        guard let key = ProcessInfo.processInfo.environment["PORTKEY_API_KEY"] else { throw UsageError.noKey }
        try Credentials.save(key)
        UserDefaults.standard.set(NSUserName(), forKey: "user")
        print("Portkey API key saved in Keychain for \(NSUserName()).")
        exit(0)
    } catch {
        print(error.localizedDescription)
        exit(1)
    }
}

if CommandLine.arguments.contains("--check") {
    Task {
        do {
            let user = UserDefaults.standard.string(forKey: "user") ?? NSUserName()
            let period = UsagePeriod.saved()
            let usage = try await PortkeyClient().fetch(key: Credentials.read(), user: user, period: period)
            print("\(usage.title) · \(period.rawValue) · \(user)")
            print("Launch at login: \(SMAppService.mainApp.status == .enabled)")
            exit(0)
        } catch {
            print(error.localizedDescription)
            exit(1)
        }
    }
    RunLoop.main.run()
}

let application = NSApplication.shared
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
editItem.submenu = editMenu
let mainMenu = NSMenu()
mainMenu.addItem(editItem)
application.mainMenu = mainMenu
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
