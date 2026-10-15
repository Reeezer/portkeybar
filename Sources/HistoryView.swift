import SwiftUI

// Command Line Tools lack the SDK's State macro plugin, so use the property wrapper.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct RankingHistoryView: View {
    @ObservedObject var history: RankingHistory
    var onRefresh: () -> Void
    var onClose: () -> Void
    @ViewState private var selectedDate: Date?
    @AppStorage("historyColorMode") private var colorMode = HistoryColorMode.rank
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(at: context.date)
        }
        .padding(12)
        .frame(width: 300, height: 228)
        .font(.system(size: 12))
        .onExitCommand(perform: onClose)
    }

    private func content(at now: Date) -> some View {
        let today = Calendar.current.startOfDay(for: now)
        let dates = RankingHistory.gridDates(at: now)
        let inspected = selectedDate ?? today
        let maximumCost = history.maximumCost(in: dates.filter { $0 <= today })
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Grid color", selection: $colorMode) {
                ForEach(HistoryColorMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented).controlSize(.small).labelsHidden()
            .accessibilityLabel("Grid color")
            .help(colorMode == .rank ? "Rank relative to the largest squad size observed. #1 is darkest."
                  : "Daily cost / highest daily cost in this grid.")
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(dates.prefix(7)), id: \.self) { date in
                        Text(date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 10)).frame(width: 32, height: 14, alignment: .leading)
                    }
                }
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<13) { week in
                        let weekDates = Array(dates.dropFirst(week * 7).prefix(7))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(monthLabel(dates: dates, week: week))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize().frame(width: 14, height: 14, alignment: .leading)
                                .accessibilityHidden(true)
                            ForEach(weekDates, id: \.self) { date in
                                let day = history.day(date)
                                Button { selectedDate = date } label: {
                                    cell(fraction: day.flatMap {
                                        colorMode.fraction(for: $0.usage, maximumCost: maximumCost, squadSize: history.squadSize)
                                    }, isWeekend: Calendar.current.isDateInWeekend(date))
                                        .overlay(RoundedRectangle(cornerRadius: 3)
                                            .stroke(inspected == date ? Color.accentColor : .clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                                .help(dayLabel(date, today: today))
                                .accessibilityLabel(dayLabel(date, today: today))
                                .onHover { inside in
                                    if inside && date <= today { selectedDate = date }
                                }
                                .disabled(date > today)
                                .opacity(date <= today ? 1 : 0)
                                .accessibilityHidden(date > today)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text(dayLabel(inspected, today: today)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if let message = history.message {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary).help(message).accessibilityLabel(message)
                }
                if history.isLoading {
                    ProgressView().controlSize(.mini).accessibilityLabel("Loading ranking history")
                } else {
                    Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh history").accessibilityLabel("Refresh history")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(fraction: Double?, isWeekend: Bool) -> some View {
        let weekendShade = colorScheme == .dark ? Color.black.opacity(0.5) : Color.secondary.opacity(0.25)
        return RoundedRectangle(cornerRadius: 3)
            .fill(fraction.map { $0 > 0 ? activityColor($0) : Color.secondary.opacity(0.1) } ?? .clear)
            .background(isWeekend && (fraction ?? 0) == 0 ? weekendShade : .clear,
                        in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(fraction == nil ? 0.25 : 0.1)))
            .frame(width: 14, height: 14)
    }

    private func activityColor(_ fraction: Double) -> Color {
        if colorScheme == .dark {
            return Color(red: 0.06 + 0.29 * fraction, green: 0.21 + 0.70 * fraction, blue: 0.10 + 0.40 * fraction)
        }
        return Color(red: 0.90 - 0.84 * fraction, green: 0.98 - 0.62 * fraction, blue: 0.90 - 0.76 * fraction)
    }

    private func dayLabel(_ date: Date, today: Date) -> String {
        let label = date.formatted(date: .abbreviated, time: .omitted)
        guard let day = history.day(date) else { return "\(label) · No data yet" }
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
        var note = ""
        if date == today { note = " · so far" }
        else if day.fetchedAt < nextDay { note = " · last seen" }
        let people = colorMode == .rank ? history.squadSize.map { "/\($0)" } ?? "" : ""
        return "\(label) · \(day.usage.title)\(people)\(note)"
    }

    private func monthLabel(dates: [Date], week: Int) -> String {
        guard let date = dates.dropFirst(week * 7).first,
              week == 0 || !Calendar.current.isDate(date, equalTo: dates[(week - 1) * 7], toGranularity: .month) else { return "" }
        return date.formatted(.dateTime.month(.abbreviated))
    }
}
