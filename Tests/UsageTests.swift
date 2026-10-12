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
    static func main() async throws {
        var rejected = 0
        let decoder = JSONDecoder()
        let numeric = try decoder.decode(UserCost.self, from: Data(#"{"user":"me","cost":1234.2}"#.utf8))
        let text = try decoder.decode(UserCost.self, from: Data(#"{"user":"me","cost":"1234.2"}"#.utf8))
        assert(numeric == text)
        let ranked = try Usage(rows: [numeric, UserCost(user: "other", cost: 2000),
                                     UserCost(user: "tie", cost: numeric.cost), UserCost(user: "", cost: 99999)], user: "me")
        assert(ranked.title == "12.34$ #2", "Convert cents and rank actual people by unrounded cost")
        let absent = try Usage(rows: [numeric, UserCost(user: "zero", cost: 0)], user: "absent")
        assert(absent.title == "0.00$ #2")
        let empty = try Usage(rows: [], user: "me")
        assert(empty.title == "0.00$ #1")
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
        let requests = StubProtocol.state.capturedRequests()
        assert(requests.count == 2)
        for (index, request) in requests.enumerated() {
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value!) })
            assert(query["current_page"] == String(index))
            assert(query["page_size"] == "100")
            assert(formatter.date(from: query["time_of_generation_max"]!)! == now)
            assert(formatter.date(from: query["time_of_generation_min"]!)! == now.addingTimeInterval(-86_400))
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
                assert(formatter.date(from: query["time_of_generation_min"]!)! == period.startDate(endingAt: now),
                       "Use the selected range on every analytics page")
                assert(formatter.date(from: query["time_of_generation_max"]!)! == now)
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
        assert(rejected == 10, "Every invalid analytics scenario must be rejected")
        print("Usage checks passed: ranking, ties, cents, time ranges, calendar boundaries, saved preference, pagination, invalid data, HTTP errors, quota.")
    }
}
