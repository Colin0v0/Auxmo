import Foundation
import AuxmoCore
import CoreAudio
import Testing
@testable import Auxmo

struct ListeningStatisticsPeriodTests {
    @Test func statisticsNavigationAndRangesHaveEnglishLabels() {
        #expect(L10n.text("观测", language: .english) == "Insights")
        #expect(L10n.text("统计", language: .english) == "Statistics")
        #expect(ListeningStatisticsPeriod.allCases.map(\.englishTitle) == ["7d", "30d", "90d", "180d", "1y", "All"])
    }

    @Test @MainActor func changingRangeClearsSelectionAndExpandedRankings() {
        let presentation = ListeningStatisticsPresentation()
        presentation.selectedDate = Date()
        presentation.allDevices = true
        presentation.allApplications = true

        presentation.selectPeriod(.week)

        #expect(presentation.period == .week)
        #expect(presentation.selectedDate == nil)
        #expect(!presentation.allDevices)
        #expect(!presentation.allApplications)
    }

    @Test(arguments: ListeningStatisticsPeriod.allCases.filter { $0 != .all })
    func rangeIncludesExactlyTheSelectedNumberOfLocalDates(period: ListeningStatisticsPeriod) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 16)))
        let days = period.days(endingAt: now, calendar: calendar)

        #expect(days.count == period.rawValue)
        #expect(Set(days).count == period.rawValue)
        #expect(days.last == calendar.startOfDay(for: now))
        #expect(days.allSatisfy { calendar.component(.hour, from: $0) == 0 })
        #expect(days.first == calendar.date(byAdding: .day, value: 1 - period.rawValue,
                                           to: calendar.startOfDay(for: now)))
    }

    @Test func allRangeStartsAtEarliestRecordOrToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12)))
        let first = try #require(calendar.date(from: DateComponents(year: 2025, month: 12, day: 1, hour: 9)))
        let days = ListeningStatisticsPeriod.all.days(endingAt: now, calendar: calendar, firstRecord: first)
        #expect(days.first == calendar.startOfDay(for: first))
        #expect(days.last == calendar.startOfDay(for: now))
        #expect(ListeningStatisticsPeriod.all.days(endingAt: now, calendar: calendar).count == 1)
        #expect(ListeningStatisticsPeriod.all.axisDates(for: days, calendar: calendar).count <= 7)
    }

    @Test func daylightSavingChangeDoesNotSkipOrDuplicateADay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let days = ListeningStatisticsPeriod.week.days(endingAt: now, calendar: calendar)

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
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 16)))
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

    private func bucket(at date: Date, seconds: Double) -> ListeningStatisticsBucket {
        ListeningStatisticsBucket(start: date, deviceUID: "test-output", deviceName: "测试耳机",
                                  deviceKind: .headphones, applicationID: "test-app",
                                  applicationName: "测试应用", seconds: seconds)
    }
}
