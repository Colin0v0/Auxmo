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

/// 范围包含今天，从本地午夜开始，保证汇总、柱状图和热力图使用同一条日期边界。
enum ListeningStatisticsPeriod: Int, CaseIterable, Identifiable {
    case today = 1
    case week = 7
    case month = 30
    case quarter = 90
    case halfYear = 180
    case year = 365
    case all = 0
    case custom = -1

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .today: return "今天"
        case .custom: return "自定义"
        case .year: return "一年"
        case .all: return "全部"
        default: return "\(rawValue) 天"
        }
    }

    var englishTitle: String {
        switch self {
        case .today: return "Today"
        case .custom: return "Custom"
        case .week: return "7d"
        case .month: return "30d"
        case .quarter: return "90d"
        case .halfYear: return "180d"
        case .year: return "1y"
        case .all: return "All"
        }
    }

    func days(endingAt date: Date, calendar: Calendar, firstRecord: Date? = nil, customRange: ClosedRange<Date>? = nil) -> [Date] {
        if self == .custom {
            guard let customRange else { preconditionFailure("自定义日期范围尚未设置") }
            return ListeningDateRange(start: customRange.lowerBound, end: customRange.upperBound,
                                      now: date, calendar: calendar).days(calendar: calendar)
        }
        let today = calendar.startOfDay(for: date)
        // 全部范围从最早记录当天开始；没有历史记录时显示今天。
        let count: Int
        if self == .all, let firstRecord, firstRecord < today {
            count = calendar.dateComponents([.day], from: calendar.startOfDay(for: firstRecord), to: today).day! + 1
        } else {
            count = self == .all ? 1 : rawValue
        }
        return (0..<count).map {
            calendar.date(byAdding: .day, value: $0 - count + 1, to: today)!
        }
    }

    /// 与图表按天分桶的柱形中心一致；夏令时切换日按真实日长度取中点。
    func dayCenter(_ date: Date, calendar: Calendar) -> Date {
        let interval = calendar.dateInterval(of: .day, for: date)!
        return interval.start.addingTimeInterval(interval.duration / 2)
    }

    func axisDates(for days: [Date], calendar: Calendar) -> [Date] {
        stride(from: 0, to: days.count, by: max(axisStride, (days.count + 6) / 7)).map {
            dayCenter(days[$0], calendar: calendar)
        }
    }

    var axisStride: Int {
        switch self {
        case .today, .custom, .week: return 1
        case .month: return 7
        case .quarter: return 21
        case .halfYear: return 30
        case .year: return 60
        case .all: return 1
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
