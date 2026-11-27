import Foundation
import AuxmoCore
import CoreAudio
import Testing
@testable import Auxmo

struct ListeningStatisticsPeriodTests {
    @Test func dailyAveragesDistinguishRecordedDaysFromSelectedDays() {
        let averages = ListeningDailyAverages(total: 160 * 60, activeDays: 2, selectedDays: 30)
        #expect(averages.activeDay == 80 * 60)
        #expect(averages.selectedDay == 320)
        let empty = ListeningDailyAverages(total: 0, activeDays: 0, selectedDays: 30)
        #expect(empty.activeDay == 0)
        #expect(empty.selectedDay == 0)
    }

    @Test func statisticsNavigationAndRangesHaveEnglishLabels() {
        #expect(L10n.text("观测", language: .english) == "Insights")
        #expect(L10n.text("统计", language: .english) == "Statistics")
        #expect(ListeningStatisticsPeriod.allCases.map(\.title) == ["本周", "上周", "本月", "上月", "今年", "自定义"])
        #expect(ListeningStatisticsPeriod.allCases.map(\.englishTitle) ==
                ["This Week", "Last Week", "This Month", "Last Month", "This Year", "Custom"])
    }

    @Test @MainActor func changingRangeClearsSelectionAndExpandedRankings() {
        let presentation = ListeningStatisticsPresentation()
        #expect(presentation.period == .week)
        presentation.hoveredChartDate = Date()
        presentation.allDevices = true
        presentation.allApplications = true

        presentation.selectPeriod(.month)

        #expect(presentation.period == .month)
        #expect(presentation.hoveredChartDate == nil)
        #expect(!presentation.allDevices)
        #expect(!presentation.allApplications)
    }

    @Test func shortcutsUseCalendarBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 16)))
        func day(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
        }
        let week = ListeningStatisticsPeriod.week.days(endingAt: now, calendar: calendar)
        #expect(week.count == 7 && week.first == (day(11, 23)) && week.last == (day(11, 29)))
        let lastWeek = ListeningStatisticsPeriod.lastWeek.days(endingAt: now, calendar: calendar)
        #expect(lastWeek.count == 7 && lastWeek.first == (day(11, 16)) && lastWeek.last == (day(11, 22)))
        #expect(ListeningStatisticsPeriod.month.days(endingAt: now, calendar: calendar).first == (day(11, 1)))
        let lastMonth = ListeningStatisticsPeriod.lastMonth.days(endingAt: now, calendar: calendar)
        #expect(lastMonth.first == day(10, 1))
        #expect(lastMonth.last == day(10, 31))
        #expect(ListeningStatisticsPeriod.year.days(endingAt: now, calendar: calendar).first == (day(1, 1)))
    }

    @Test func customRangeIncludesBothCalendarEndpoints() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12)))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 18)))
        let days = ListeningStatisticsPeriod.custom.days(endingAt: now, calendar: calendar,
                                                         customRange: start...end)

        #expect(days.count == 3)
        #expect(days.first == calendar.startOfDay(for: start))
        #expect(days.last == calendar.startOfDay(for: end))
    }

    @Test func daylightSavingChangeDoesNotSkipOrDuplicateADay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 4)))
        let days = ListeningStatisticsPeriod.custom.days(endingAt: now, calendar: calendar, customRange: first...now)

        #expect(days.map { calendar.component(.day, from: $0) } == [4, 5, 6, 7, 8, 9, 10])
        // 按日历加一天，夏令时开始的这一天只有 23 小时，不能以固定 86400 秒递增。
        #expect(days[5].timeIntervalSince(days[4]) == 23 * 60 * 60)
        let centers = ListeningStatisticsPeriod.week.axisDates(for: days, calendar: calendar)
        #expect(centers.count == days.count)
        for (day, center) in zip(days, centers) {
            let interval = try #require(calendar.dateInterval(of: .day, for: day))
            #expect(center == interval.start.addingTimeInterval(interval.duration / 2))
        }
    }

    @Test @MainActor func totalsAndChartShareTheInclusiveFirstDayBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 16)))
        let days = ListeningStatisticsPeriod.week.days(endingAt: now, calendar: calendar)
        let domain = "auxmo.statistics.period-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let buckets = [
            bucket(at: days[0].addingTimeInterval(-1), seconds: 900),
            bucket(at: days[0], seconds: 60),
            bucket(at: now, seconds: 120)
        ]
        defaults.set(try JSONEncoder().encode(buckets), forKey: "com.colin0v0.auxmo.listeningStatistics.v1")
        let store = ListeningStatisticsStore(defaults: defaults)
        let totals = store.dailyTotals(since: days[0], calendar: calendar)

        #expect(store.totalSeconds(since: days[0]) == 180)
        #expect(days.reduce(0) { $0 + totals[$1, default: 0] } == 180)
        #expect(store.activeDayCount(since: days[0], calendar: calendar) == 2)
        #expect(store.deviceSummaries(since: days[0]).first?.seconds == 180)
        #expect(store.applicationSummaries(since: days[0]).first?.seconds == 180)
    }

    @Test @MainActor func simultaneousAppsAndDevicesCountElapsedTimeOnce() throws {
        let domain = "auxmo.statistics.overlap-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ListeningStatisticsStore(defaults: defaults)
        let devices = [AudioOutput(id: 1, uid: "a", name: "耳机", transport: kAudioDeviceTransportTypeBluetooth),
                       AudioOutput(id: 2, uid: "b", name: "音响", transport: kAudioDeviceTransportTypeUSB)]
        let apps = ["one", "two"].map {
            ApplicationAudioRow(id: "bundle:\($0)", bundleID: $0, name: $0,
                                applicationURL: nil, group: nil, isRunningOutput: true)
        }
        let start = Date()
        store.record(at: start, outputs: devices, applications: apps)
        store.record(at: start.addingTimeInterval(15), outputs: devices, applications: apps)
        store.record(at: start.addingTimeInterval(30), outputs: devices, applications: apps)
        #expect(store.totalSeconds() == 30)
        #expect(store.deviceSummaries().map(\.seconds) == [30, 30])
        #expect(store.applicationSummaries().map(\.seconds) == [30, 30])
        #expect(store.sessionDurations() == [30])
        store.persist()
        let reopened = ListeningStatisticsStore(defaults: defaults)
        #expect(reopened.totalSeconds() == 30)
        #expect(reopened.deviceSummaries().map(\.seconds) == [30, 30])
    }

    @Test @MainActor func scopedDetailsAndDataManagementUseRealRecordedIntervals() throws {
        let domain = "auxmo.statistics.detail.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ListeningStatisticsStore(defaults: defaults)
        let headphones = AudioOutput(id: 1, uid: "headphones", name: "耳机", transport: kAudioDeviceTransportTypeBluetooth)
        let speaker = AudioOutput(id: 2, uid: "speaker", name: "音响", transport: kAudioDeviceTransportTypeUSB)
        let appA = ApplicationAudioRow(id: "a", bundleID: "a", name: "A", applicationURL: nil, group: nil, isRunningOutput: true)
        let appB = ApplicationAudioRow(id: "b", bundleID: "b", name: "B", applicationURL: nil, group: nil, isRunningOutput: true)
        let start = Date()
        store.record(at: start, outputs: [headphones], applications: [appA])
        store.record(at: start.addingTimeInterval(15), outputs: [headphones], applications: [appA])
        store.record(at: start.addingTimeInterval(30), outputs: [headphones, speaker], applications: [appA, appB])
        #expect(store.totalSeconds(scope: .device("headphones")) == 30)
        #expect(store.totalSeconds(scope: .device("speaker")) == 15)
        #expect(store.totalSeconds(scope: .application("b")) == 15)
        #expect(store.applicationSummaries(scope: .device("speaker")).map(\.seconds) == [15, 15])
        #expect(store.deviceSummaries(scope: .application("b")).map(\.seconds) == [15, 15])
        #expect(store.dailyTotals(scope: .device("speaker")).values.reduce(0, +) == 15)
        #expect(store.heatmap(scope: .application("b")).flatMap { $0 }.reduce(0, +) == 0.25)
        #expect(store.firstRecordedDate(scope: .device("speaker")) == start.addingTimeInterval(15))
        let data = try store.exportData()
        let archive = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(archive["formatVersion"] as? Int == 3)
        #expect((archive["intervals"] as? [Any])?.count == 2)
        try store.clearAll()
        #expect(store.firstRecordedDate() == nil)
        #expect(store.totalSeconds() == 0)
        let restored = ListeningStatisticsStore(defaults: defaults)
        #expect(restored.totalSeconds() == 0)
        // 清空后第一次采样只建立基点，不把清空前的间隔重新统计进去。
        store.record(at: start.addingTimeInterval(45), outputs: [headphones], applications: [appA])
        #expect(store.totalSeconds() == 0)
    }

    @Test @MainActor func differentAppRoutesNeverCreateCrossProductPairs() throws {
        let domain = "auxmo.statistics.route-pairs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ListeningStatisticsStore(defaults: defaults)
        let headphone = AudioOutput(id: 1, uid: "headphones", name: "耳机", transport: kAudioDeviceTransportTypeBluetooth)
        let speaker = AudioOutput(id: 2, uid: "speaker", name: "音响", transport: kAudioDeviceTransportTypeUSB)
        let appA = ApplicationAudioRow(id: "a", bundleID: "a", name: "A", applicationURL: nil, group: nil, isRunningOutput: true)
        let appB = ApplicationAudioRow(id: "b", bundleID: "b", name: "B", applicationURL: nil, group: nil, isRunningOutput: true)
        let first = [ListeningPlaybackObservation(application: appA, outputs: [headphone]),
                     ListeningPlaybackObservation(application: appB, outputs: [speaker])]
        let switched = [ListeningPlaybackObservation(application: appA, outputs: [speaker]),
                        ListeningPlaybackObservation(application: appB, outputs: [headphone])]
        let start = Date()
        store.record(at: start, observations: first)
        store.record(at: start.addingTimeInterval(15), observations: first)
        #expect(store.totalSeconds() == 15)
        #expect(store.deviceSummaries(scope: .application("a")).map(\.id) == ["headphones"])
        #expect(store.applicationSummaries(scope: .device("speaker")).map(\.id) == ["b"])
        store.record(at: start.addingTimeInterval(30), observations: switched)
        #expect(store.totalSeconds() == 30)
        #expect(Set(store.deviceSummaries(scope: .application("a")).map(\.id)) == Set(["headphones", "speaker"]))
        #expect(store.deviceSummaries(scope: .application("a")).allSatisfy { $0.seconds == 15 })
        store.persist()
        let restored = ListeningStatisticsStore(defaults: defaults)
        #expect(restored.applicationSummaries(scope: .device("speaker")).allSatisfy { $0.seconds == 15 })
        #expect(restored.totalSeconds() == 30)
    }

    @Test @MainActor func inactiveGapIsNotChargedToTheNextRoute() throws {
        let domain = "auxmo.statistics.route-gap.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ListeningStatisticsStore(defaults: defaults)
        let output = AudioOutput(id: 1, uid: "headphones", name: "耳机", transport: kAudioDeviceTransportTypeBluetooth)
        let app = ApplicationAudioRow(id: "a", bundleID: "a", name: "A", applicationURL: nil, group: nil, isRunningOutput: true)
        let active = [ListeningPlaybackObservation(application: app, outputs: [output])]
        let start = Date()
        store.record(at: start, observations: active)
        store.record(at: start.addingTimeInterval(15), observations: active)
        store.record(at: start.addingTimeInterval(20), observations: [])
        store.record(at: start.addingTimeInterval(55), observations: [])
        store.record(at: start.addingTimeInterval(70), observations: active)
        #expect(store.totalSeconds() == 30)
    }

    @Test @MainActor func unknownOrPausedRoutesAreNotAttributedToAnOutput() throws {
        let domain = "auxmo.statistics.unknown-route.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ListeningStatisticsStore(defaults: defaults)
        let app = ApplicationAudioRow(id: "a", bundleID: "a", name: "A", applicationURL: nil, group: nil, isRunningOutput: true)
        let start = Date()
        let unknown = [ListeningPlaybackObservation(application: app, outputs: [])]
        store.record(at: start, observations: unknown)
        store.record(at: start.addingTimeInterval(15), observations: unknown)
        #expect(store.totalSeconds() == 0)
        #expect(store.deviceSummaries().isEmpty)
        #expect(store.applicationSummaries().isEmpty)
    }

    @Test @MainActor func continuousPlaybackAcrossAnHourRemainsOneSession() throws {
        let domain = "auxmo.statistics.continuous.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ListeningStatisticsStore(defaults: defaults)
        let device = AudioOutput(id: 1, uid: "a", name: "耳机", transport: kAudioDeviceTransportTypeBluetooth)
        let app = ApplicationAudioRow(id: "bundle:one", bundleID: "one", name: "one",
                                      applicationURL: nil, group: nil, isRunningOutput: true)
        let hour = try #require(Calendar.current.dateInterval(of: .hour, for: Date()))
        let start = hour.end.addingTimeInterval(-30)
        for tick in 0...8 {
            store.record(at: start.addingTimeInterval(Double(tick * 15)), outputs: [device], applications: [app])
        }
        #expect(store.totalSeconds() == 120)
        #expect(store.sessionDurations() == [120])
        #expect(store.heatmap().flatMap { $0 }.reduce(0, +) == 2)
    }

    @Test @MainActor func legacyOverlappingBucketsAreNotSummedAsConcurrentTime() throws {
        let domain = "auxmo.statistics.legacy-overlap.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [bucket(at: time, seconds: 60),
                    ListeningStatisticsBucket(start: time, deviceUID: "other", deviceName: "音响",
                        deviceKind: .externalSpeaker, applicationID: "other-app", applicationName: "应用", seconds: 90)]
        defaults.set(try JSONEncoder().encode(rows), forKey: "com.colin0v0.auxmo.listeningStatistics.v1")
        let store = ListeningStatisticsStore(defaults: defaults)
        #expect(store.totalSeconds() == 90)
        #expect(store.dailyTotals().values.reduce(0, +) == 90)
        #expect(store.sessionDurations() == [90])
    }

    @Test @MainActor func legacyDetailsFilterByDeviceAndApplication() throws {
        let domain = "auxmo.statistics.legacy-detail.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [
            ListeningStatisticsBucket(start: date, deviceUID: "headphones", deviceName: "耳机",
                                      deviceKind: .headphones, applicationID: "music", applicationName: "音乐", seconds: 90),
            ListeningStatisticsBucket(start: date, deviceUID: "speaker", deviceName: "音响",
                                      deviceKind: .externalSpeaker, applicationID: "music", applicationName: "音乐", seconds: 90),
            ListeningStatisticsBucket(start: date, deviceUID: "headphones", deviceName: "耳机",
                                      deviceKind: .headphones, applicationID: "meeting", applicationName: "会议", seconds: 30)
        ]
        defaults.set(try JSONEncoder().encode(rows), forKey: "com.colin0v0.auxmo.listeningStatistics.v1")
        let store = ListeningStatisticsStore(defaults: defaults)
        #expect(store.totalSeconds(scope: .device("headphones")) == 90)
        #expect(store.totalSeconds(scope: .application("music")) == 90)
        #expect(store.applicationSummaries(scope: .device("headphones")).count == 2)
        #expect(store.deviceSummaries(scope: .application("meeting")).map(\.id) == ["headphones"])
        #expect(store.firstRecordedDate(scope: .application("meeting")) == date)
        #expect(store.firstRecordedDate(scope: .application("missing")) == nil)
    }

    private func bucket(at date: Date, seconds: Double) -> ListeningStatisticsBucket {
        ListeningStatisticsBucket(start: date, deviceUID: "test-output", deviceName: "测试耳机",
                                  deviceKind: .headphones, applicationID: "test-app",
                                  applicationName: "测试应用", seconds: seconds)
    }
}
