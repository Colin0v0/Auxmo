import Foundation

/// 两种日均分别保留明确分母，空记录时不除以零。
struct ListeningDailyAverages {
    let activeDay: Double
    let selectedDay: Double

    init(total: Double, activeDays: Int, selectedDays: Int) {
        activeDay = activeDays > 0 ? total / Double(activeDays) : 0
        selectedDay = selectedDays > 0 ? total / Double(selectedDays) : 0
    }
}

/// 快捷范围按用户本地日历计算；固定周期展示完整自然区间，自定义范围不延伸到未来。
enum ListeningStatisticsPeriod: CaseIterable, Identifiable {
    case week, lastWeek, month, lastMonth, year, custom

    var id: Self { self }
    var title: String {
        switch self {
        case .week: return "本周"
        case .lastWeek: return "上周"
        case .month: return "本月"
        case .lastMonth: return "上月"
        case .year: return "今年"
        case .custom: return "自定义"
        }
    }

    var englishTitle: String {
        switch self {
        case .week: return "This Week"
        case .lastWeek: return "Last Week"
        case .month: return "This Month"
        case .lastMonth: return "Last Month"
        case .year: return "This Year"
        case .custom: return "Custom"
        }
    }

    func days(endingAt date: Date, calendar: Calendar, firstRecord: Date? = nil, customRange: ClosedRange<Date>? = nil) -> [Date] {
        let today = calendar.startOfDay(for: date)
        let start: Date
        let end: Date
        switch self {
        case .week:
            let mondayOffset = (calendar.component(.weekday, from: today) + 5) % 7
            let thisMonday = calendar.date(byAdding: .day, value: -mondayOffset, to: today)!
            start = thisMonday
            end = calendar.date(byAdding: .day, value: 6, to: thisMonday)!
        case .lastWeek:
            let mondayOffset = (calendar.component(.weekday, from: today) + 5) % 7
            let thisMonday = calendar.date(byAdding: .day, value: -mondayOffset, to: today)!
            start = calendar.date(byAdding: .day, value: -7, to: thisMonday)!
            end = calendar.date(byAdding: .day, value: -1, to: thisMonday)!
        case .month:
            let interval = calendar.dateInterval(of: .month, for: today)!
            start = interval.start
            end = calendar.date(byAdding: .day, value: -1, to: interval.end)!
        case .lastMonth:
            // 上月范围从原月第一天到本月第一天前一日，按本地日历跨月计算。
            let thisMonthStart = calendar.dateInterval(of: .month, for: today)!.start
            start = calendar.date(byAdding: .month, value: -1, to: thisMonthStart)!
            end = calendar.date(byAdding: .day, value: -1, to: thisMonthStart)!
        case .year:
            let interval = calendar.dateInterval(of: .year, for: today)!
            start = interval.start
            end = calendar.date(byAdding: .day, value: -1, to: interval.end)!
        case .custom:
            guard let customRange else { preconditionFailure("自定义日期范围尚未设置") }
            start = customRange.lowerBound; end = customRange.upperBound
        }
        if self == .custom {
            return ListeningDateRange(start: start, end: end, now: date, calendar: calendar).days(calendar: calendar)
        }
        // 快捷周期保留完整刻度，尚未到来的日期由统计数据自然填成零值。
        let count = calendar.dateComponents([.day], from: start, to: end).day! + 1
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    /// 刻度按自然日中心排列；夏令时日期使用真实的日长度。
    func dayCenter(_ date: Date, calendar: Calendar) -> Date {
        let interval = calendar.dateInterval(of: .day, for: date)!
        return interval.start.addingTimeInterval(interval.duration / 2)
    }

    func axisDates(for days: [Date], calendar: Calendar) -> [Date] {
        stride(from: 0, to: days.count, by: max(1, (days.count + 6) / 7)).map {
            dayCenter(days[$0], calendar: calendar)
        }
    }
}

/// 日期选择包含结束日；查询使用下一天午夜作排他上界，按日历运算适配夏令时。
struct ListeningDateRange {
    let start: Date
    let end: Date
    let until: Date

    init(start: Date, end: Date, now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        let first = min(calendar.startOfDay(for: start), today)
        let last = min(calendar.startOfDay(for: end), today)
        self.start = min(first, last)
        self.end = max(first, last)
        until = calendar.date(byAdding: .day, value: 1, to: self.end)!
    }

    func days(calendar: Calendar) -> [Date] {
        let count = calendar.dateComponents([.day], from: start, to: end).day! + 1
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }
}
