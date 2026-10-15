import AppKit
import SwiftUI

@main
@MainActor
struct PreviewHistory {
    static func main() async throws {
        let suite = "local.portkeybar.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = RankingHistory(defaults: defaults)
        history.selectProfile(key: "preview", user: "preview")
        let today = Calendar.current.startOfDay(for: Date())
        for (index, date) in RankingHistory.gridDates(at: today).enumerated() where date <= today && index % 9 != 0 {
            let zeroSpend = index % 7 == 0 || (Calendar.current.isDateInWeekend(date) && index % 3 == 0)
            let costs = (0..<(index % 9 + 1)).map { UserCost(user: "person\($0)", cost: Double(($0 + 1) * 200)) }
                + [UserCost(user: "preview", cost: zeroSpend ? 0 : Double(index * 13))]
            await history.refresh(key: "preview", user: "preview", now: date.addingTimeInterval(3_600),
                                  todayUsage: try Usage(rows: costs, user: "preview"))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let previewAction = { /* Static previews do not refresh analytics or close a running app. */ }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            for mode in HistoryColorMode.allCases {
                defaults.set(mode.rawValue, forKey: "historyColorMode")
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 228),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let view = NSHostingView(rootView: RankingHistoryView(history: history,
                                                                     onRefresh: previewAction, onClose: previewAction)
                    .environment(\.colorScheme, scheme)
                    .defaultAppStorage(defaults)
                    .background(Color(nsColor: .windowBackgroundColor)))
                window.contentView = view
                window.layoutIfNeeded()
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: URL(fileURLWithPath: ".build/preview-history-\(mode.rawValue.lowercased())-\(name).png"))
            }
        }
        print("Rendered rank and spend history previews in light and dark mode using sample data.")
    }
}
