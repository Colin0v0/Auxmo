import SwiftUI
import Charts

/// 统计页沿用控制页的浅灰底和紧凑字体，用间距区分信息层级。
struct ListeningStatisticsView: View {
    @ObservedObject var statistics: ListeningStatisticsStore
    @StateObject private var presentation: ListeningStatisticsPresentation
    @Environment(\.appLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var english: Bool { language == .english }
    private func text(_ chinese: String, _ english: String) -> String { self.english ? english : chinese }
    private var displayLocale: Locale { Locale(identifier: english ? "en_US" : "zh_CN") }
    private let calendar: Calendar
    private let now: Date
    private let showsScrollView: Bool
    private var period: ListeningStatisticsPeriod { presentation.period }
    private var selectedDate: Date? { presentation.selectedDate }
    private var compact: Bool { presentation.compact }
    private var scope: ListeningStatisticsScope? { presentation.detail?.scope }

    init(statistics: ListeningStatisticsStore, now: Date = Date(), calendar: Calendar = .current,
         showsScrollView: Bool = false) {
        self.statistics = statistics
        self.now = now
        self.calendar = calendar
        self.showsScrollView = showsScrollView
        _presentation = StateObject(wrappedValue: ListeningStatisticsPresentation())
    }

    /// 完整窗口共享导航状态，使面包屑和页面始终指向同一详情。
    init(statistics: ListeningStatisticsStore, presentation: ListeningStatisticsPresentation,
         now: Date = Date(), calendar: Calendar = .current, showsScrollView: Bool = false) {
        self.statistics = statistics
        self.now = now
        self.calendar = calendar
        self.showsScrollView = showsScrollView
        _presentation = StateObject(wrappedValue: presentation)
    }

    private var days: [Date] { period.days(endingAt: now, calendar: calendar, firstRecord: statistics.firstRecordedDate(scope: scope)) }
    private var since: Date { days[0] }
    private var total: Double { statistics.totalSeconds(since: since, scope: scope) }
    private var activeDays: Int { statistics.dailyTotals(since: since, calendar: calendar, scope: scope).count }
    private var devices: [ListeningDeviceSummary] { statistics.deviceSummaries(since: since, scope: scope) }
    private var applications: [ListeningApplicationSummary] { statistics.applicationSummaries(since: since, scope: scope) }
    private var dailyPoints: [ListeningDayPoint] {
        let totals = statistics.dailyTotals(since: since, calendar: calendar, scope: scope)
        return days.map { ListeningDayPoint(date: $0, seconds: totals[$0, default: 0]) }
    }

    var body: some View {
        Group {
            if showsScrollView {
                ScrollViewReader { proxy in
                    ScrollView {
                        pageBody
                            .id("statistics-top")
                            // 统计页由窗口导航栏提供顶部层级，内容直接贴在导航栏下方，
                            // 避免进入统计或详情时多出一段空白。
                            .padding(.horizontal, 24).padding(.top, 0).padding(.bottom, 28)
                            .background(DashboardScrollbars())
                    }
                    .onChange(of: presentation.detail?.scope) { _, _ in
                        // 从排行进入详情或返回时，总是从标题开始阅读。
                        proxy.scrollTo("statistics-top", anchor: .top)
                    }
                }
            } else {
                pageBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: showsScrollView ? .infinity : nil, alignment: .topLeading)
        .environment(\.calendar, calendar)
    }

    private var pageBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail = presentation.detail {
                detailHeader(detail).padding(.bottom, 20)
            }
            // 日期与统计内容一起滚动，不固定在窗口顶部。
            periodPicker
            statisticsContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { $0.size.width < 560 } action: { presentation.compact = $0 }
    }

    private var statisticsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            overview
                .padding(.top, 22)
                .padding(.bottom, 24)
            dailyChart
                .padding(.bottom, 22)
            sectionDivider

            // 详情展示另一维度的关联排行；总览仍并排展示设备和应用。
            if let detail = presentation.detail {
                switch detail.scope {
                case .device: applicationRanking.padding(.vertical, 20)
                case .application: deviceRanking.padding(.vertical, 20)
                }
            } else if compact {
                deviceRanking.padding(.vertical, 20)
                sectionDivider
                applicationRanking.padding(.vertical, 20)
            } else {
                HStack(alignment: .top, spacing: 32) {
                    deviceRanking
                    applicationRanking
                }
                .padding(.vertical, 22)
            }
            sectionDivider
            timeHeatmap.padding(.vertical, 20)
            sectionDivider
            sessionStatistics.padding(.top, 14)
        }
    }

    private func detailHeader(_ detail: ListeningStatisticsDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                presentation.returnToOverview()
            } label: {
                Label(text("返回统计", "Back to Statistics"), systemImage: "chevron.left")
                    .font(PanelStyle.bodyFont)
                    .foregroundStyle(presentation.hoveredBack ? PanelStyle.ink : PanelStyle.secondary)
            }
            .buttonStyle(.plain)
            .onHover { presentation.hoveredBack = $0 }
            HStack(spacing: 10) {
                rankingIcon(detail.icon).frame(width: 24, height: 24)
                Text(detail.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            }
        }
    }

    private var sectionDivider: some View {
        Rectangle().fill(PanelStyle.line.opacity(0.75)).frame(height: 0.5)
    }

    private var periodPicker: some View {
        // 窄面板分两行，保证六个范围按钮始终完整可点。
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                             : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            Text("\(rangeDateLabel(since)) – \(rangeDateLabel(days[days.count - 1]))")
                .font(PanelStyle.bodyFont)
                .foregroundStyle(PanelStyle.secondary)
                .lineLimit(1)
                .help("\(dateLabel(since)) – \(dateLabel(days[days.count - 1]))")
            if !compact { Spacer(minLength: 0) }
            PanelTabs(items: ListeningStatisticsPeriod.allCases, selection: period,
                      title: { english ? $0.englishTitle : $0.title }, select: presentation.selectPeriod)
                .frame(maxWidth: compact ? .infinity : 390)
        }
    }

    private var overview: some View {
        let valueSize: CGFloat = compact ? 24 : 28
        let averages = ListeningDailyAverages(total: total, activeDays: activeDays, selectedDays: days.count)
        return HStack(alignment: .top, spacing: compact ? 10 : 12) {
            metric(text("累计聆听", "Total Listening"), detail: comparisonText) {
                durationValue(total, size: valueSize)
            }
            metric(text("平均每天", "Daily Average"), detail: text(
                "所选天数日均 \(durationText(averages.selectedDay))",
                "Selected-day avg \(durationText(averages.selectedDay))")) {
                // 主数字仅计算有记录的日期；下方另列所选全部日期的平均值。
                durationValue(averages.activeDay, size: valueSize)
            }
            .help(text("总时长 ÷ 有记录的 \(activeDays) 天", "Total time ÷ \(activeDays) recorded days"))
            if !compact {
                metric(text("活跃天数", "Active Days"), detail: text("占所选天数 \(Int((Double(activeDays) / Double(days.count) * 100).rounded()))%", "\(Int((Double(activeDays) / Double(days.count) * 100).rounded()))% of selected days")) {
                    countValue(activeDays, unit: text("天", activeDays == 1 ? "day" : "days"), size: valueSize)
                }
            }
        }
    }

    /// 用等长的完整自然日比较，全部范围不显示不合理的上一周期。
    private var comparisonText: String {
        guard period != .all else { return text("全部记录", "All records") }
        let previousStart = calendar.date(byAdding: .day, value: -days.count, to: since)!
        let previous = statistics.totalSeconds(since: previousStart, until: since, scope: scope)
        guard previous > 0 else { return text("上一周期暂无记录", "No previous-period data") }
        let difference = total - previous
        if abs(difference) < 60 { return text("与上一周期基本持平", "Similar to previous period") }
        return english ? "\(durationText(abs(difference))) \(difference > 0 ? "more" : "less") than previous period" : "较上一周期\(difference > 0 ? "增加" : "减少") \(durationText(abs(difference)))"
    }

    private func metric<Value: View>(_ title: String, detail: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary)
            value()
            Text(detail).font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        // 统计数字共用等宽白色卡片，深色外观沿用系统自适应的深灰表面。
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(PanelStyle.tabSelection, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private var dailyChart: some View {
        let points = dailyPoints
        let maximum = chartMaximum(points)
        let selected = selectedDate.flatMap { date in
            points.first { calendar.isDate($0.date, inSameDayAs: date) }
        }
        let end = calendar.date(byAdding: .day, value: 1, to: days[days.count - 1])!
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(text("每日聆听", "Daily Listening")).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let selected {
                    Text("\(dateLabel(selected.date)) · \(durationText(selected.seconds))")
                        .font(PanelStyle.captionFont)
                        .foregroundStyle(PanelStyle.secondary)
                        .monospacedDigit()
                }
            }
            Chart {
                ForEach(points) { point in
                    // 每日时长是离散数据；空白日期不以折线连接，也不生成虚构的播放趋势。
                    BarMark(x: .value(text("日期", "Date"), point.date, unit: .day),
                            y: .value(text("时长", "Duration"), point.seconds / 60),
                            width: .ratio(0.56))
                    .cornerRadius(2)
                    .foregroundStyle(PanelStyle.accent.opacity(
                        selected == nil || selected?.date == point.date ? 0.72 : 0.22))
                    .accessibilityLabel(dateLabel(point.date))
                    .accessibilityValue(durationText(point.seconds))
                }
                if let selected {
                    RuleMark(x: .value(text("选中日期", "Selected Date"), period.dayCenter(selected.date, calendar: calendar)))
                        .foregroundStyle(PanelStyle.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .accessibilityHidden(true)
                }
            }
            .chartXScale(domain: since...end)
            // 时长不能为负；零刻度贴紧绘图区底边，避免默认留白看起来像负数范围。
            .chartYScale(domain: 0...maximum, range: .plotDimension(startPadding: 0, endPadding: 0))
            .chartXSelection(value: $presentation.selectedDate)
            .chartXAxis {
                // 刻度落在对应日期的中心，与柱形和选中虚线使用同一坐标。
                AxisMarks(values: period.axisDates(for: days, calendar: calendar)) { value in
                    AxisValueLabel(centered: false, anchor: .top, collisionResolution: .disabled, offsetsMarks: false) {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(Date.FormatStyle().month(.defaultDigits).day().locale(displayLocale)))
                                .font(.system(size: 10))
                                .foregroundStyle(PanelStyle.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                // 明确给出三条刻度，避免空数据时出现两次“0 分”。
                AxisMarks(position: .trailing, values: [0, maximum / 2, maximum]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(PanelStyle.line.opacity(0.7))
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) {
                            Text(durationText(minutes * 60))
                                .font(.system(size: 10))
                                .foregroundStyle(PanelStyle.secondary)
                        }
                    }
                }
            }
            .chartPlotStyle { $0.padding(.top, 4) }
            .frame(height: compact ? 136 : 156)
            .overlay {
                if total == 0 {
                    Text(text("暂无聆听记录", "No listening records"))
                        .font(PanelStyle.bodyFont)
                        .foregroundStyle(PanelStyle.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(PanelStyle.canvas)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// 纵轴以完整的 15 分钟或小时进位；空图保留 0、30 分、1 小时三个可区分的刻度。
    private func chartMaximum(_ points: [ListeningDayPoint]) -> Double {
        let peak = points.reduce(0) { max($0, $1.seconds / 60) }
        guard peak > 0 else { return 60 }
        let step: Double = peak <= 60 ? 15 : 60
        return max(30, ceil(peak / step) * step)
    }

    private var deviceRanking: some View {
        ranking(title: text("输出设备", "Output Devices"), emptyText: text("暂无设备记录", "No device records"),
                rows: devices.map { ListeningRankingItem(id: $0.id, title: $0.name,
                                                         seconds: $0.seconds, icon: .device(deviceSymbol($0.kind))) },
                expanded: $presentation.allDevices)
    }

    private var applicationRanking: some View {
        ranking(title: text("应用", "Apps"), emptyText: text("暂无应用记录", "No app records"),
                rows: applications.map { ListeningRankingItem(id: $0.id, title: $0.name,
                                                              seconds: $0.seconds, icon: .application($0.id)) },
                expanded: $presentation.allApplications)
    }

    private func ranking(title: String, emptyText: String, rows: [ListeningRankingItem],
                         expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(rows.count)").font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary)
            }
            .padding(.bottom, 12)
            if rows.isEmpty {
                Text(emptyText)
                    .font(PanelStyle.bodyFont).foregroundStyle(PanelStyle.secondary)
                    .padding(.vertical, 12)
            }
            ForEach(rows.prefix(expanded.wrappedValue ? rows.count : 5)) { row in
                rankingRow(row)
            }
            if rows.count > 5 {
                Button(expanded.wrappedValue ? text("收起", "Show Less") : text("查看全部 \(rows.count) 项", "Show All \(rows.count)")) {
                    expanded.wrappedValue.toggle()
                }
                .buttonStyle(.plain)
                .font(PanelStyle.captionFont)
                .foregroundStyle(PanelStyle.secondary)
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func rankingRow(_ row: ListeningRankingItem) -> some View {
        let denominator = row.icon.isDevice ? devices.reduce(0) { $0 + $1.seconds } : applications.reduce(0) { $0 + $1.seconds }
        let share = denominator > 0 ? row.seconds / denominator : 0
        let selectedScope: ListeningStatisticsScope = row.icon.isDevice ? .device(row.id) : .application(row.id)
        let hovered = presentation.hoveredRanking == selectedScope
        return Button {
            presentation.detail = ListeningStatisticsDetail(scope: selectedScope, title: row.title, icon: row.icon)
            presentation.selectedDate = nil
            presentation.hoveredRanking = nil
        } label: {
        HStack(alignment: .top, spacing: 10) {
            rankingIcon(row.icon, highlighted: hovered)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(PanelStyle.bodyFont)
                        .foregroundStyle(PanelStyle.ink)
                        .lineLimit(1)
                        .help(row.title)
                    Spacer(minLength: 0)
                    Text(durationText(row.seconds))
                        .font(PanelStyle.captionFont)
                        .foregroundStyle(hovered ? PanelStyle.ink : PanelStyle.secondary)
                        .monospacedDigit()
                        .fixedSize()
                    // 轻量提示这一行可进入设备或应用详情。
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(hovered ? PanelStyle.ink : PanelStyle.secondary.opacity(0.7))
                        .accessibilityHidden(true)
                }
                // 细线只表达所选范围内的时长占比，不给整行铺装饰底板。
                GeometryReader { proxy in
                    Rectangle().fill(PanelStyle.line.opacity(0.45))
                    Rectangle().fill(PanelStyle.accent.opacity(0.5))
                        .frame(width: proxy.size.width * min(share, 1))
                }
                .frame(height: 2)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 每行各自响应悬停，鼠标移出后恢复默认颜色，不改变布局。
        .onHover { hovering in
            if hovering { presentation.hoveredRanking = selectedScope }
            else if presentation.hoveredRanking == selectedScope { presentation.hoveredRanking = nil }
        }
        .help(text("\(row.title) · \(durationText(row.seconds)) · 排行总时长的 \(Int((share * 100).rounded()))%", "\(row.title) · \(durationText(row.seconds)) · \(Int((share * 100).rounded()))% of listed time"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text("\(row.title)，\(durationText(row.seconds))，占排行总时长 \(Int((share * 100).rounded()))%", "\(row.title), \(durationText(row.seconds)), \(Int((share * 100).rounded()))% of listed time"))
    }

    @ViewBuilder
    private func rankingIcon(_ icon: ListeningRankingIcon, highlighted: Bool = false) -> some View {
        switch icon {
        case .device(let symbol):
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(highlighted ? PanelStyle.ink : PanelStyle.secondary)
        case .application(let identity):
            // 保留应用原始彩色图标；无对应应用包时只保留对齐位置。
            if let image = ApplicationIconCache.icon(forApplicationIdentity: identity) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
    }

    private var timeHeatmap: some View {
        let values = statistics.heatmap(since: since, calendar: calendar, scope: scope)
        let peak = values.flatMap { $0 }.max()!
        let weekdays = english ? ["M", "T", "W", "T", "F", "S", "S"] : ["一", "二", "三", "四", "五", "六", "日"]
        let weekdayNames = english ? ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] : ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 5) {
                Text(text("使用时段", "Listening Hours")).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let cell = presentation.hoveredHeatmapCell {
                    // 悬停时立即显示完整时段和累计时长，避免依赖系统延迟提示。
                    Text("\(weekdayNames[cell.day]) \(cell.hour):00–\(cell.hour + 1):00 · \(durationText(values[cell.day][cell.hour] * 60))")
                        .font(PanelStyle.captionFont)
                        .foregroundStyle(PanelStyle.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                } else {
                    Text(text("少", "Less")).font(.system(size: 10)).foregroundStyle(PanelStyle.secondary)
                    ForEach(0..<4) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(heatColor(Double(level), peak: 3))
                            .frame(width: 9, height: 9)
                    }
                    Text(text("多", "More")).font(.system(size: 10)).foregroundStyle(PanelStyle.secondary)
                }
            }
            VStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { day in
                    // 星期标签与格子放在同一行，底部小时轴不再使星期整体错位。
                    HStack(spacing: 4) {
                        Text(weekdays[day])
                            .font(.system(size: 10))
                            .foregroundStyle(PanelStyle.secondary)
                            .frame(width: 18)
                        ForEach(0..<24, id: \.self) { hour in
                            let label = "\(weekdayNames[day]) \(hour):00–\(hour + 1):00 · \(durationText(values[day][hour] * 60))"
                            let hovered = presentation.hoveredHeatmapCell == HeatmapCell(day: day, hour: hour)
                            RoundedRectangle(cornerRadius: hovered ? 3 : 2)
                                .fill(heatColor(values[day][hour], peak: peak))
                                .frame(maxWidth: .infinity)
                                // 悬停格子轻微放大并浮起，保留列宽不变，避免热力图整体跳动。
                                .frame(height: hovered ? 14 : 11)
                                .shadow(color: hovered ? .black.opacity(0.18) : .clear,
                                        radius: hovered ? 3 : 0, y: hovered ? 2 : 0)
                                .scaleEffect(hovered ? 1.08 : 1, anchor: .center)
                                .zIndex(hovered ? 2 : 0)
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    let cell = HeatmapCell(day: day, hour: hour)
                                    if hovering { presentation.hoveredHeatmapCell = cell }
                                    else if presentation.hoveredHeatmapCell == cell { presentation.hoveredHeatmapCell = nil }
                                }
                                .help(label)
                                .accessibilityLabel(label)
                                .animation(PanelStyle.animation(reduceMotion: reduceMotion), value: hovered)
                        }
                    }
                }
                HStack(spacing: 4) {
                    Color.clear.frame(width: 18, height: 1).accessibilityHidden(true)
                    ForEach(0..<24, id: \.self) { hour in
                        // 标签叠在等宽格子上，双位小时不会把窄面板的列撑开或折成两行。
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 12)
                            .overlay {
                                if hour % (compact ? 6 : 3) == 0 {
                                    Text("\(hour)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(PanelStyle.secondary)
                                        .fixedSize()
                                }
                            }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// 无记录的时段使用中性灰；有记录的格子按所选范围内的最大值归一化。
    private func heatColor(_ value: Double, peak: Double) -> Color {
        guard value > 0, peak > 0 else { return PanelStyle.line.opacity(0.5) }
        return PanelStyle.accent.opacity(0.18 + min(value / peak, 1) * 0.65)
    }

    private var sessionStatistics: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 会话明细始终展开，标题与“使用时段”使用同一字号和颜色。
            Text(text("会话明细", "Session Details"))
                .font(.system(size: 13, weight: .semibold))
                .help(text("会话根据音频活跃采样及时间间隔估算，历史记录精度为 15 分钟。", "Sessions are estimated from audio activity; historical records use 15-minute intervals."))

            let durations = statistics.sessionDurations(since: since, scope: scope)
            VStack(spacing: 12) {
                sessionRow(text("使用次数", "Sessions"), value: english ? "\(durations.count)" : "\(durations.count) 次")
                sessionRow(text("平均每次", "Average Session"), value: durationText(
                    durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)))
                sessionRow(text("最长一次", "Longest Session"), value: durationText(durations.max() ?? 0))
                if let busiest = dailyPoints.filter({ $0.seconds > 0 }).max(by: { $0.seconds < $1.seconds }) {
                    sessionRow(text("听得最多的一天", "Most Active Day"), value: "\(dateLabel(busiest.date)) · \(durationText(busiest.seconds))")
                }
                if let hour = busiestHour {
                    sessionRow(text("最常用时段", "Most Active Hour"), value: "\(hour):00–\(hour + 1):00")
                }
                if compact { sessionRow(text("活跃天数", "Active Days"), value: english ? "\(activeDays) \(activeDays == 1 ? "day" : "days")" : "\(activeDays) 天") }
            }
            .padding(.top, 14).padding(.bottom, 4)
        }
    }

    private var busiestHour: Int? {
        let heat = statistics.heatmap(since: since, calendar: calendar, scope: scope)
        let totals = (0..<24).map { hour in heat.reduce(0) { $0 + $1[hour] } }
        guard let hour = totals.indices.max(by: { totals[$0] < totals[$1] }), totals[hour] > 0 else { return nil }
        return hour
    }

    private func sessionRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(PanelStyle.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(PanelStyle.bodyFont)
    }

    /// 数字与单位共享基线；整小时不追加“0 分钟”，不足一分钟明确显示。
    private func durationValue(_ seconds: Double, size: CGFloat) -> some View {
        let minutes = Int(seconds / 60)
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            if minutes >= 60 { countValue(minutes / 60, unit: "小时", size: size) }
            if minutes % 60 != 0 || minutes < 60 {
                countValue(minutes % 60, unit: "分钟", size: size, lessThanOne: seconds > 0 && minutes == 0)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(durationText(seconds))
    }

    private func countValue(_ value: Int, unit: String, size: CGFloat, lessThanOne: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(lessThanOne ? "<1" : "\(value)")
                .font(.system(size: size, weight: .medium)).monospacedDigit()
            Text(english ? (unit == "小时" ? (value == 1 ? "hr" : "hrs") : (unit == "分钟" ? "min" : unit)) : unit).font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func durationText(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if english {
            if seconds > 0, minutes == 0 { return "<1 min" }
            if minutes < 60 { return "\(minutes) min" }
            if minutes % 60 == 0 { return "\(minutes / 60) hr" }
            return "\(minutes / 60) hr \(minutes % 60) min"
        }
        if seconds > 0, minutes == 0 { return "不足 1 分钟" }
        if minutes < 60 { return "\(minutes) 分" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    private func dateLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().month().day().locale(displayLocale))
    }

    /// 窄面板缩短日期格式，给时间范围控件保留完整的点击宽度。
    private func rangeDateLabel(_ date: Date) -> String {
        calendar.component(.year, from: since) != calendar.component(.year, from: days[days.count - 1])
            ? date.formatted(Date.FormatStyle().year().month(.defaultDigits).day().locale(displayLocale))
            : (compact ? date.formatted(Date.FormatStyle().month(.defaultDigits).day().locale(displayLocale)) : dateLabel(date))
    }

    private func deviceSymbol(_ kind: ListeningDeviceKind) -> String {
        switch kind {
        case .headphones: return "headphones"
        case .builtInSpeaker: return "laptopcomputer"
        case .externalSpeaker: return "hifispeaker"
        case .display: return "display"
        case .other: return "speaker.wave.2"
        }
    }
}

/// 交互状态随视图实例保存；与音频采样、持久化记录保持独立。
@MainActor
final class ListeningStatisticsPresentation: ObservableObject {
    @Published private(set) var period: ListeningStatisticsPeriod = .month
    @Published var selectedDate: Date?
    @Published var compact = false
    @Published var allDevices = false
    @Published var allApplications = false
    @Published var hoveredHeatmapCell: HeatmapCell?
    @Published var hoveredBack = false
    @Published var hoveredRanking: ListeningStatisticsScope?
    @Published fileprivate var detail: ListeningStatisticsDetail?

    var detailTitle: String? { detail?.title }

    /// 返回总览同时清理详情的选择和悬停状态。
    func returnToOverview() {
        detail = nil
        selectedDate = nil
        hoveredBack = false
        hoveredRanking = nil
    }

    /// 切换范围时同步清除旧图表选中日和列表展开状态，避免显示上个范围的明细。
    func selectPeriod(_ value: ListeningStatisticsPeriod) {
        guard value != period else { return }
        selectedDate = nil
        hoveredHeatmapCell = nil
        allDevices = false
        allApplications = false
        period = value
    }
}

private struct ListeningDayPoint: Identifiable {
    let date: Date
    let seconds: Double
    var id: Date { date }
}

private struct ListeningRankingItem: Identifiable {
    let id: String
    let title: String
    let seconds: Double
    let icon: ListeningRankingIcon
}

private struct ListeningStatisticsDetail {
    let scope: ListeningStatisticsScope
    let title: String
    let icon: ListeningRankingIcon
}

private enum ListeningRankingIcon {
    case device(String)
    case application(String)
    var isDevice: Bool {
        if case .device = self { return true }
        return false
    }
}

/// 热力图悬停状态只记录行列，显示内容始终来自当前统计数据。
struct HeatmapCell: Equatable {
    let day: Int
    let hour: Int
}
