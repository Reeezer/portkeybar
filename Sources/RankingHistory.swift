import Foundation
import Combine
import CryptoKit

struct RankingDay: Codable, Equatable {
    let usage: Usage
    let fetchedAt: Date
}

enum HistoryColorMode: String, CaseIterable {
    case rank = "Rank"
    case spend = "Spend"

    func fraction(for usage: Usage, maximumCost: Double, squadSize: Int?) -> Double? {
        if usage.dollars == 0 { return 0 }
        switch self {
        case .rank:
            guard let squadSize, squadSize > 0, usage.rank > 0, usage.rank <= squadSize else { return nil }
            return Double(squadSize - usage.rank + 1) / Double(squadSize)
        case .spend:
            return maximumCost > 0 ? min(usage.dollars / maximumCost, 1) : 0
        }
    }
}

@MainActor
final class RankingHistory: ObservableObject {
    @Published private(set) var days: [String: RankingDay] = [:]
    @Published var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var squadSize: Int?
    private let defaults: UserDefaults
    private let client: PortkeyClient
    private var storageKey: String?
    private var observedSizeKey: String?

    init(defaults: UserDefaults = .standard, client: PortkeyClient = PortkeyClient()) {
        self.defaults = defaults
        self.client = client
    }

    func day(_ date: Date, calendar: Calendar = .current) -> RankingDay? {
        days[Self.key(date, calendar: calendar)]
    }

    func maximumCost(in dates: [Date], calendar: Calendar = .current) -> Double {
        dates.compactMap { day($0, calendar: calendar)?.usage.dollars }.max() ?? 0
    }

    func resetProfile() {
        storageKey = nil
        observedSizeKey = nil
        squadSize = nil
        days = [:]
        message = nil
    }

    func selectProfile(key: String, user: String, calendar: Calendar = .current) {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = "rankingHistory.\(digest).\(user).\(calendar.timeZone.identifier)"
        guard storageKey != name else { return }
        resetProfile()
        storageKey = name
        let sizeKey = "maxObservedPeople.\(digest)"
        observedSizeKey = sizeKey
        let size = defaults.integer(forKey: sizeKey)
        squadSize = size > 0 ? size : nil
        if let data = defaults.data(forKey: name) {
            do { days = try JSONDecoder().decode([String: RankingDay].self, from: data) }
            catch { message = "Saved history could not be read. Refresh to load it from Portkey." }
        }
        for day in days.values { observe(day.usage) }
    }

    func observe(_ usage: Usage) {
        // shortcut: unseen members are unknown, use the roster if an exact total becomes necessary.
        let size = max(usage.people ?? usage.rank, usage.rank)
        guard size > (squadSize ?? 0) else { return }
        squadSize = size
        if let observedSizeKey { defaults.set(size, forKey: observedSizeKey) }
    }

    func reportFailure(_ error: any Error) {
        message = "History: \(error.localizedDescription) Saved days are kept; refresh to retry."
    }

    func refresh(key: String, user: String, now: Date = Date(), todayUsage: Usage? = nil,
                 includePast: Bool = false, calendar: Calendar = .current) async {
        guard !Task.isCancelled else { return }
        selectProfile(key: key, user: user, calendar: calendar)
        isLoading = true
        message = nil
        defer { isLoading = false }
        let today = calendar.startOfDay(for: now)
        let dates = includePast ? Self.gridDates(at: now, calendar: calendar).filter { $0 <= today }.reversed() : [today].reversed()
        do {
            for date in dates {
                try Task.checkCancellation()
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: date) else {
                    throw UsageError.invalidData
                }
                // shortcut: completed days stay cached; re-fetch them if Portkey starts revising settled analytics.
                if date < today, let saved = day(date, calendar: calendar),
                   saved.fetchedAt >= nextDay, saved.usage.people != nil { continue }
                let usage: Usage
                if date == today, let todayUsage { usage = todayUsage }
                else {
                    // End before midnight so adjacent days cannot include the same request.
                    usage = try await client.fetch(key: key, user: user, start: date, end: min(now, nextDay.addingTimeInterval(-0.001)))
                }
                try Task.checkCancellation()
                days[Self.key(date, calendar: calendar)] = RankingDay(usage: usage, fetchedAt: now)
                observe(usage)
                if let storageKey { defaults.set(try JSONEncoder().encode(days), forKey: storageKey) }
            }
        } catch {
            guard !Task.isCancelled else { return }
            reportFailure(error)
        }
    }

    static func gridDates(at date: Date, calendar: Calendar = .current) -> [Date] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date),
              let start = calendar.date(byAdding: .weekOfYear, value: -12, to: week.start) else { return [] }
        return (0..<91).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
