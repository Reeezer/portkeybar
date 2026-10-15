import Foundation

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, Data)] = []
    private var requests: [URLRequest] = []

    func reset(_ replies: [(Int, Data)]) {
        lock.lock()
        defer { lock.unlock() }
        self.replies = replies
        requests = []
    }

    func next(_ request: URLRequest) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        precondition(!replies.isEmpty, "Unexpected analytics request")
        return replies.removeFirst()
    }

    func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let state = StubState()
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data) = Self.state.next(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        // Responses are delivered synchronously, so no pending work needs cancellation.
    }
}

@main
enum UsageTests {
    @MainActor
    static func main() async throws {
        var rejected = 0
        let decoder = JSONDecoder()
        let numeric = try decoder.decode(UserCost.self, from: Data(#"{"user":"me","cost":1234.2}"#.utf8))
        let text = try decoder.decode(UserCost.self, from: Data(#"{"user":"me","cost":"1234.2"}"#.utf8))
        assert(numeric == text)
        let ranked = try Usage(rows: [numeric, UserCost(user: "other", cost: 2000),
                                     UserCost(user: "tie", cost: numeric.cost), UserCost(user: "", cost: 99999)], user: "me")
        assert(ranked.title == "12.34$ #2", "Convert cents and rank actual people by unrounded cost")
        assert(ranked.people == 3, "Count actual people, including ties, and exclude anonymous analytics")
        let absent = try Usage(rows: [numeric, UserCost(user: "zero", cost: 0)], user: "absent")
        assert(absent.title == "0.00$ #2")
        assert(absent.people == 3, "Include the configured user even when they have no usage row")
        let empty = try Usage(rows: [], user: "me")
        assert(empty.title == "0.00$ #1")
        assert(empty.people == 1)
        try checkColorRatios()
        do {
            _ = try Usage(rows: [numeric, numeric], user: "me")
            assertionFailure("Duplicate users must fail")
        } catch UsageError.invalidData { rejected += 1 }
        for bad in [#"{"user":"me","cost":-1}"#, #"{"user":"me","cost":"NaN"}"#,
                    #"{"user":"me","cost":"unknown"}"#] {
            do {
                _ = try decoder.decode(UserCost.self, from: Data(bad.utf8))
                assertionFailure("Invalid costs must fail")
            } catch { rejected += 1 }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = PortkeyClient(session: URLSession(configuration: config))
        let now = Date(timeIntervalSince1970: 1_791_543_600)
        let durations: [(UsagePeriod, TimeInterval)] = [
            (.last1Hour, 3_600), (.last5Hours, 18_000), (.last24Hours, 86_400),
            (.last3Days, 259_200), (.last7Days, 604_800), (.last14Days, 1_209_600), (.last30Days, 2_592_000)
        ]
        for (period, duration) in durations {
            assert(now.timeIntervalSince(period.startDate(endingAt: now)) == duration)
        }
        let formatter = ISO8601DateFormatter()
        let requestFormatter = ISO8601DateFormatter()
        requestFormatter.formatOptions.insert(.withFractionalSeconds)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        calendar.firstWeekday = 2
        for (timestamp, dayStart, weekStart, monthStart) in [
            ("2026-10-15T10:00:00Z", "2026-10-14T22:00:00Z", "2026-10-11T22:00:00Z", "2026-09-30T22:00:00Z"),
            ("2026-03-29T12:00:00Z", "2026-03-28T23:00:00Z", "2026-03-22T23:00:00Z", "2026-02-28T23:00:00Z"),
            ("2026-10-25T12:00:00Z", "2026-10-24T22:00:00Z", "2026-10-18T22:00:00Z", "2026-09-30T22:00:00Z"),
            ("2027-01-01T12:00:00Z", "2026-12-31T23:00:00Z", "2026-12-27T23:00:00Z", "2026-12-31T23:00:00Z")
        ] {
            let date = formatter.date(from: timestamp)!
            for (period, start) in [(UsagePeriod.today, dayStart), (.thisWeek, weekStart), (.thisMonth, monthStart)] {
                assert(period.startDate(endingAt: date, calendar: calendar) == formatter.date(from: start)!,
                       "Calendar ranges must respect local midnight, daylight saving, and year boundaries")
            }
            assert(UsagePeriod.last24Hours.startDate(endingAt: date) == date.addingTimeInterval(-86_400))
        }
        calendar.firstWeekday = 1
        assert(UsagePeriod.thisWeek.startDate(endingAt: formatter.date(from: "2026-10-15T10:00:00Z")!, calendar: calendar)
               == formatter.date(from: "2026-10-10T22:00:00Z")!, "Use the Mac's configured first weekday")

        let suite = "local.portkeybar.usage.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        assert(UsagePeriod.saved(in: defaults) == .last24Hours, "Default to the past 24 hours")
        assert(UsagePeriod.allCases.count == 10)
        for period in UsagePeriod.allCases {
            defaults.set(period.rawValue, forKey: "timeRange")
            assert(UsagePeriod.saved(in: UserDefaults(suiteName: suite)!) == period, "Restore every saved range")
        }
        defaults.set("unknown", forKey: "timeRange")
        assert(UsagePeriod.saved(in: defaults) == .last24Hours, "Invalid saved ranges fall back to 24 hours")

        let rows: [[String: Any]] = (0..<100).map { ["user": "user\($0)", "cost": 200] }
        let first = try JSONSerialization.data(withJSONObject: ["total": 101, "cost_unit": "cents", "data": rows])
        let last = Data(#"{"total":101,"data":[{"user":"me","cost":"100"}]}"#.utf8)
        StubProtocol.state.reset([(200, first), (200, last)])
        let paged = try await client.fetch(key: "test-key", user: "me", now: now)
        assert(paged.title == "1.00$ #101", "Ranking must include every page")
        assert(paged.people == 101, "Learn the people count from every page")
        let requests = StubProtocol.state.capturedRequests()
        assert(requests.count == 2)
        for (index, request) in requests.enumerated() {
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value!) })
            assert(query["current_page"] == String(index))
            assert(query["page_size"] == "100")
            assert(requestFormatter.date(from: query["time_of_generation_max"]!)! == now)
            assert(requestFormatter.date(from: query["time_of_generation_min"]!)! == now.addingTimeInterval(-86_400))
            assert(request.value(forHTTPHeaderField: "x-portkey-api-key") == "test-key")
        }

        for period in UsagePeriod.allCases {
            StubProtocol.state.reset([(200, first), (200, last)])
            let usage = try await client.fetch(key: "test-key", user: "me", period: period, now: now)
            assert(usage.title == "1.00$ #101")
            let requests = StubProtocol.state.capturedRequests()
            assert(requests.count == 2)
            for request in requests {
                let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    .queryItems!.map { ($0.name, $0.value!) })
                assert(requestFormatter.date(from: query["time_of_generation_min"]!)! == period.startDate(endingAt: now),
                       "Use the selected range on every analytics page")
                assert(requestFormatter.date(from: query["time_of_generation_max"]!)! == now)
            }
        }

        for reply in [
            (403, Data()),
            (200, Data(#"{"total":2,"data":[{"user":"me","cost":1}]}"#.utf8)),
            (200, Data(#"{"total":0,"data":[],"is_quota_exceeded":true}"#.utf8)),
            (200, Data(#"{"total":0,"data":[],"cost_unit":"dollars"}"#.utf8))
        ] {
            StubProtocol.state.reset([reply])
            do {
                _ = try await client.fetch(key: "test-key", user: "me", now: now)
                assertionFailure("Denied or incomplete analytics must fail")
            } catch is UsageError { rejected += 1 }
        }
        StubProtocol.state.reset([(200, first), (200, Data(#"{"total":100,"data":[]}"#.utf8))])
        do {
            _ = try await client.fetch(key: "test-key", user: "me", now: now)
            assertionFailure("Changing totals must fail instead of silently misranking")
        } catch UsageError.invalidData { rejected += 1 }
        do {
            _ = try await client.fetch(key: "", user: "me", now: now)
            assertionFailure("Missing credentials must fail")
        } catch UsageError.noKey { rejected += 1 }
        StubProtocol.state.reset([])
        do {
            _ = try await client.fetch(key: "test-key", user: "me", start: now, end: now.addingTimeInterval(-1))
            assertionFailure("Reversed date bounds must fail before making a request")
        } catch UsageError.invalidData { rejected += 1 }
        assert(rejected == 11, "Every invalid analytics scenario must be rejected")
        let historyNow = formatter.date(from: "2026-03-30T12:00:00Z")!
        calendar.firstWeekday = 2
        let grid = RankingHistory.gridDates(at: historyNow, calendar: calendar)
        let today = calendar.startOfDay(for: historyNow)
        assert(grid.count == 91 && calendar.component(.weekday, from: grid[0]) == 2,
               "The grid has 13 complete weeks, starting on the configured first weekday")
        assert(Set(grid.map { calendar.startOfDay(for: $0) }).count == 91)
        assert(grid.contains(today), "Today's cell stays in the grid across month and DST boundaries")
        let history = RankingHistory(defaults: defaults, client: client)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        StubProtocol.state.reset([(200, Data(#"{"total":1,"data":[{"user":"me","cost":100}]}"#.utf8))])
        await history.refresh(key: "test-key", user: "me", now: yesterday.addingTimeInterval(3_600), calendar: calendar)
        assert(history.day(yesterday, calendar: calendar)?.usage.title == "1.00$ #1")
        assert(history.squadSize == 1, "Learn the squad size automatically from the first response")
        let pastDates = grid.filter { $0 <= today }.reversed()
        let dailyReply = Data(#"{"total":2,"data":[{"user":"me","cost":100},{"user":"other","cost":200}]}"#.utf8)
        StubProtocol.state.reset(pastDates.map { _ in (200, dailyReply) })
        await history.refresh(key: "test-key", user: "me", now: historyNow, includePast: true, calendar: calendar)
        assert(history.message == nil && !history.isLoading)
        assert(history.squadSize == 2, "Increase the estimate when a larger population is observed")
        let historyRequests = StubProtocol.state.capturedRequests()
        assert(historyRequests.count == pastDates.count, "Re-fetch yesterday's partial ranking, and load missing days")
        for (date, request) in zip(pastDates, historyRequests) {
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value!) })
            let nextDay = calendar.date(byAdding: .day, value: 1, to: date)!
            assert(requestFormatter.date(from: query["time_of_generation_min"]!) == date)
            let fetchedEnd = requestFormatter.date(from: query["time_of_generation_max"]!)!
            assert(abs(fetchedEnd.timeIntervalSince(min(historyNow, nextDay.addingTimeInterval(-0.001)))) < 0.000_001,
                   "Fetch calendar days, including the 23-hour DST day, independently of the selected range")
            assert(fetchedEnd < nextDay, "Midnight requests cannot appear in two daily rankings")
        }
        assert(today.timeIntervalSince(yesterday) == 23 * 3_600)
        assert(history.day(yesterday, calendar: calendar)?.usage.title == "1.00$ #2",
               "A provisional day is replaced by the final daily rank")
        StubProtocol.state.reset([(200, dailyReply)])
        await history.refresh(key: "test-key", user: "me", now: historyNow, includePast: true, calendar: calendar)
        assert(StubProtocol.state.capturedRequests().count == 1, "Completed past days are cached; today stays fresh")
        StubProtocol.state.reset([])
        await history.refresh(key: "test-key", user: "me", now: historyNow, todayUsage: ranked, calendar: calendar)
        assert(history.day(today, calendar: calendar)?.usage == ranked, "Reuse the menu's Today response")
        assert(history.maximumCost(in: [yesterday], calendar: calendar) == 1,
               "Spending normalization excludes higher costs outside the displayed dates")
        assert(history.maximumCost(in: [today, yesterday], calendar: calendar) == ranked.dollars)
        assert(history.maximumCost(in: [], calendar: calendar) == 0)
        assert(history.squadSize == 3)
        history.observe(paged)
        history.observe(empty)
        assert(history.squadSize == 101, "Quiet days cannot reduce the largest count observed, including menu queries")
        let observedKey = defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("maxObservedPeople.") }!
        defaults.set(999, forKey: observedKey.replacingOccurrences(of: "maxObservedPeople.", with: "squadSize."))
        var legacyDays = history.days
        let legacyUsage = try decoder.decode(Usage.self, from: Data(#"{"dollars":1,"rank":7}"#.utf8))
        legacyDays["2026-03-29"] = RankingDay(usage: legacyUsage, fetchedAt: historyNow)
        let storageKey = defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("rankingHistory.") }!
        defaults.set(try JSONEncoder().encode(legacyDays), forKey: storageKey)
        defaults.removeObject(forKey: observedKey)
        let fromCache = RankingHistory(defaults: defaults, client: client)
        fromCache.selectProfile(key: "test-key", user: "me", calendar: calendar)
        assert(fromCache.squadSize == 7, "Old ranks establish a lower bound when no saved maximum or people count exists")
        fromCache.observe(paged)
        let repaired = RankingHistory(defaults: defaults, client: client)
        repaired.selectProfile(key: "test-key", user: "me", calendar: calendar)
        assert(repaired.day(yesterday, calendar: calendar)?.usage.people == nil && repaired.squadSize == 101)
        StubProtocol.state.reset([(200, dailyReply)])
        await repaired.refresh(key: "test-key", user: "me", now: historyNow, todayUsage: ranked,
                               includePast: true, calendar: calendar)
        assert(StubProtocol.state.capturedRequests().count == 1 && repaired.days == history.days,
               "Recover missing legacy people counts without re-fetching completed modern days")
        let restored = RankingHistory(defaults: UserDefaults(suiteName: suite)!, client: client)
        restored.selectProfile(key: "test-key", user: "me", calendar: calendar)
        assert(restored.days == history.days, "Daily ranks and their fetch times survive restarts")
        assert(restored.squadSize == 101, "The maximum observed size survives restarts and ignores old manual values")
        restored.selectProfile(key: "test-key", user: "someone-else", calendar: calendar)
        assert(restored.days.isEmpty, "Changing users cannot expose another user's history")
        assert(restored.squadSize == 101, "People using the same key share the maximum observed size")
        restored.selectProfile(key: "other-key", user: "me", calendar: calendar)
        assert(restored.days.isEmpty, "Changing workspace keys cannot mix rankings")
        assert(restored.squadSize == nil, "Changing keys cannot apply another squad's size")
        restored.selectProfile(key: "test-key", user: "me", calendar: calendar)
        assert(restored.days == history.days, "Switching back restores the original history")
        assert(restored.squadSize == 101)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        restored.selectProfile(key: "test-key", user: "me", calendar: utcCalendar)
        assert(restored.days.isEmpty, "A changed time zone needs different daily analytics")
        assert(restored.squadSize == 101, "Changing time zone does not lose the maximum observed size")
        assert(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.contains("test-key") },
               "The API key is not stored in preference keys")
        StubProtocol.state.reset([(200, dailyReply), (403, Data())])
        await restored.refresh(key: "other-key", user: "me", now: historyNow, includePast: true, calendar: calendar)
        assert(restored.day(today, calendar: calendar) != nil && restored.day(yesterday, calendar: calendar) == nil,
               "Partial loads keep real results and leave failed days unknown")
        assert(restored.message?.contains("access was denied") == true && !restored.isLoading)
        StubProtocol.state.reset(pastDates.map { _ in (200, dailyReply) })
        await restored.refresh(key: "other-key", user: "me", now: historyNow, includePast: true, calendar: calendar)
        assert(restored.message == nil && restored.days.count == pastDates.count, "Retry fills only missing or provisional days")
        StubProtocol.state.reset([])
        let cancelled = Task { @MainActor in
            await restored.refresh(key: "test-key", user: "me", now: historyNow, includePast: true, calendar: calendar)
        }
        cancelled.cancel()
        await cancelled.value
        assert(StubProtocol.state.capturedRequests().isEmpty, "Cancelled refreshes cannot issue requests or switch profiles")
        print("Usage checks passed: ranking, ties, cents, time ranges, calendar boundaries, saved preference, pagination, invalid data, HTTP errors, quota.")
        print("History checks passed: daily bounds, DST, provisional days, caching, persistence, profile isolation, partial failures, cancellation.")
        print("Color checks passed: maximum observed squad size, #1 darkest, zero-spend days, persistence, legacy count recovery.")
    }

    private static func checkColorRatios() throws {
        let me = UserCost(user: "me", cost: 100)
        let higher = UserCost(user: "higher", cost: 200)
        let small = try Usage(rows: [me, higher, UserCost(user: "lower", cost: 50), UserCost(user: "zero", cost: 0)], user: "me")
        let large = try Usage(rows: [me, higher] + (0..<18).map { UserCost(user: "lower\($0)", cost: 50) }, user: "me")
        assert(small.rank == 2 && large.rank == 2)
        assert(HistoryColorMode.rank.fraction(for: small, maximumCost: 2, squadSize: 20) == 0.95)
        assert(HistoryColorMode.rank.fraction(for: large, maximumCost: 2, squadSize: 20) == 0.95,
               "The maximum observed size keeps a given rank's shade stable on quiet days")
        assert(HistoryColorMode.spend.fraction(for: small, maximumCost: 2, squadSize: 20) == 0.5)
        assert(HistoryColorMode.spend.fraction(for: large, maximumCost: 2, squadSize: 4) == 0.5,
               "Spending color depends on cost, independently of squad size")
        let peak = try Usage(rows: [higher], user: "higher")
        assert(HistoryColorMode.rank.fraction(for: peak, maximumCost: 2, squadSize: 20) == 1,
               "#1 must be the darkest rank")
        assert(HistoryColorMode.spend.fraction(for: peak, maximumCost: 2, squadSize: nil) == 1)
        let zero = try Usage(rows: [UserCost(user: "me", cost: 0), UserCost(user: "other", cost: 0)], user: "me")
        assert(HistoryColorMode.spend.fraction(for: zero, maximumCost: 2, squadSize: 20) == 0)
        assert(HistoryColorMode.spend.fraction(for: zero, maximumCost: 0, squadSize: 20) == 0,
               "An all-zero grid must not divide by zero")
        assert(HistoryColorMode.rank.fraction(for: zero, maximumCost: 0, squadSize: 20) == 0,
               "Zero-spend days are gray, even when everyone shares #1")
        let tiedLast = try Usage(rows: [higher, UserCost(user: "me", cost: 0), UserCost(user: "tie", cost: 0)], user: "me")
        assert(HistoryColorMode.rank.fraction(for: tiedLast, maximumCost: 2, squadSize: 20) == 0)
        let last = try Usage(rows: [UserCost(user: "me", cost: 0)]
                            + (0..<19).map { UserCost(user: "person\($0)", cost: 100) }, user: "me")
        assert(last.rank == 20 && HistoryColorMode.rank.fraction(for: last, maximumCost: 2, squadSize: 20) == 0,
               "Zero spend at last place must be gray, matching the reported #10/10 regression")
        assert(HistoryColorMode.rank.fraction(for: zero, maximumCost: 0, squadSize: 1) == 0)
        assert(HistoryColorMode.rank.fraction(for: zero, maximumCost: 0, squadSize: nil) == 0,
               "Known zero spending is gray even before a squad size is learned")
        assert(HistoryColorMode.rank.fraction(for: small, maximumCost: 2, squadSize: nil) == nil)
        assert(HistoryColorMode.rank.fraction(for: small, maximumCost: 2, squadSize: 0) == nil)
        let lastPaid = try Usage(rows: [me] + (0..<19).map { UserCost(user: "person\($0)", cost: 200) }, user: "me")
        assert(HistoryColorMode.rank.fraction(for: lastPaid, maximumCost: 2, squadSize: 20) == 0.05,
               "A last-place day with spending still receives the lightest green shade")
        assert(HistoryColorMode.rank.fraction(for: lastPaid, maximumCost: 2, squadSize: 19) == nil,
               "A rank outside the observed squad size cannot produce a misleading shade")
        let legacy = try JSONDecoder().decode(Usage.self, from: Data(#"{"dollars":1,"rank":2,"people":2}"#.utf8))
        assert(HistoryColorMode.rank.fraction(for: legacy, maximumCost: 2, squadSize: 20) == 0.95,
               "The largest observed count takes precedence over the individual day's count")
        assert(HistoryColorMode.spend.fraction(for: legacy, maximumCost: 2, squadSize: nil) == 0.5)
        let restored = try JSONDecoder().decode(Usage.self, from: JSONEncoder().encode(small))
        assert(restored == small, "Costs and ranks survive cache encoding")
    }
}
