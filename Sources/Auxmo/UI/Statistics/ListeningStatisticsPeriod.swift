import Foundation

/// 范围包含今天，从本地午夜开始，保证汇总、柱状图和热力图使用同一条日期边界。
enum ListeningStatisticsPeriod: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90
    case halfYear = 180
    case year = 365
    case all = 0

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .year: return "一年"
        case .all: return "全部"
        default: return "\(rawValue) 天"
        }
    }

    var englishTitle: String {
        switch self {
        case .week: return "7d"
        case .month: return "30d"
        case .quarter: return "90d"
        case .halfYear: return "180d"
        case .year: return "1y"
        case .all: return "All"
        }
    }

    func days(endingAt date: Date, calendar: Calendar, firstRecord: Date? = nil) -> [Date] {
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
        case .week: return 1
        case .month: return 7
        case .quarter: return 21
        case .halfYear: return 30
        case .year: return 60
        case .all: return 1
        }
    }
}
