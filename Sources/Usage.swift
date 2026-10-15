import Foundation

enum UsagePeriod: String, CaseIterable {
    case last1Hour = "Last 1 hour"
    case last5Hours = "Last 5 hours"
    case last24Hours = "Last 24 hours"
    case last3Days = "Last 3 days"
    case last7Days = "Last 7 days"
    case last14Days = "Last 14 days"
    case last30Days = "Last 30 days"
    case today = "Today"
    case thisWeek = "This week"
    case thisMonth = "This month"

    static func saved(in defaults: UserDefaults = .standard) -> UsagePeriod {
        defaults.string(forKey: "timeRange").flatMap(UsagePeriod.init(rawValue:)) ?? .last24Hours
    }

    func startDate(endingAt now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .last1Hour: now.addingTimeInterval(-3_600)
        case .last5Hours: now.addingTimeInterval(-18_000)
        case .last24Hours: now.addingTimeInterval(-86_400)
        case .last3Days: now.addingTimeInterval(-259_200)
        case .last7Days: now.addingTimeInterval(-604_800)
        case .last14Days: now.addingTimeInterval(-1_209_600)
        case .last30Days: now.addingTimeInterval(-2_592_000)
        case .today: calendar.startOfDay(for: now)
        case .thisWeek: calendar.dateInterval(of: .weekOfYear, for: now)!.start
        case .thisMonth: calendar.dateInterval(of: .month, for: now)!.start
        }
    }
}

struct UserCost: Decodable, Equatable {
    let user: String
    let cost: Double

    private enum CodingKeys: String, CodingKey { case user, cost }

    init(user: String, cost: Double) {
        self.user = user
        self.cost = cost
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        user = try values.decode(String.self, forKey: .user)
        if let number = try? values.decode(Double.self, forKey: .cost) {
            cost = number
        } else {
            let text = try values.decode(String.self, forKey: .cost)
            guard let number = Double(text) else { throw UsageError.invalidData }
            cost = number
        }
        guard cost.isFinite, cost >= 0 else { throw UsageError.invalidData }
    }
}

struct UsagePage: Decodable {
    let total: Int
    let data: [UserCost]
    let costUnit: String?
    let quotaExceeded: Bool?

    private enum CodingKeys: String, CodingKey {
        case total, data
        case costUnit = "cost_unit"
        case quotaExceeded = "is_quota_exceeded"
    }
}

struct Usage: Codable, Equatable {
    let dollars: Double
    let rank: Int
    let people: Int?

    init(rows: [UserCost], user: String) throws {
        guard Set(rows.map(\.user)).count == rows.count else { throw UsageError.invalidData }
        let cents = rows.first { $0.user == user }?.cost ?? 0
        dollars = cents / 100
        let users = rows.filter { !$0.user.isEmpty }
        people = users.count + (users.contains { $0.user == user } || user.isEmpty ? 0 : 1)
        rank = 1 + users.filter { $0.cost > cents }.count
    }

    var title: String {
        String(format: "%.2f$ #%d", locale: Locale(identifier: "en_US_POSIX"), dollars, rank)
    }
}

enum UsageError: LocalizedError {
    case noKey, invalidData, quotaExceeded, http(Int)

    var errorDescription: String? {
        switch self {
        case .noKey: "Add your Portkey API key in Settings."
        case .invalidData: "Portkey returned incomplete or unexpected analytics."
        case .quotaExceeded: "Portkey's analytics quota is exceeded."
        case .http(401), .http(403): "Portkey access was denied. Check your API key and analytics permissions."
        case .http(let code): "Portkey could not refresh usage (HTTP \(code))."
        }
    }
}

struct PortkeyClient {
    let session: URLSession
    static let pageSize = 100

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    static func request(key: String, start: Date, now: Date, page: Int) -> URLRequest {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        var components = URLComponents(string: "https://api.portkey.ai/v1/analytics/groups/users")!
        components.queryItems = [
            URLQueryItem(name: "time_of_generation_min", value: formatter.string(from: start)),
            URLQueryItem(name: "time_of_generation_max", value: formatter.string(from: now)),
            URLQueryItem(name: "current_page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize))
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-portkey-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PortkeyBar/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    func fetch(key: String, user: String, period: UsagePeriod = .last24Hours, now: Date = Date()) async throws -> Usage {
        try await fetch(key: key, user: user, start: period.startDate(endingAt: now), end: now)
    }

    func fetch(key: String, user: String, start: Date, end: Date) async throws -> Usage {
        guard !key.isEmpty else { throw UsageError.noKey }
        guard start <= end else { throw UsageError.invalidData }
        var rows: [UserCost] = []
        var page = 0
        var expectedTotal: Int?
        while true {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: Self.request(key: key, start: start, now: end, page: page))
            guard let response = response as? HTTPURLResponse else { throw UsageError.invalidData }
            guard response.statusCode == 200 else { throw UsageError.http(response.statusCode) }
            let result = try JSONDecoder().decode(UsagePage.self, from: data)
            guard result.quotaExceeded != true else { throw UsageError.quotaExceeded }
            guard result.total >= 0, result.costUnit == nil || result.costUnit == "cents",
                  expectedTotal == nil || expectedTotal == result.total else { throw UsageError.invalidData }
            expectedTotal = result.total
            rows.append(contentsOf: result.data)
            guard rows.count <= result.total else { throw UsageError.invalidData }
            if rows.count == result.total { return try Usage(rows: rows, user: user) }
            guard result.data.count == Self.pageSize else { throw UsageError.invalidData }
            page += 1
        }
    }
}
