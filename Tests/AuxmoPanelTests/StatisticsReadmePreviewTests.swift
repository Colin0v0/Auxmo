import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Auxmo

/// 文档预览只使用独立临时偏好域和示例数据，不读取用户统计或连接设备。
@MainActor
struct StatisticsReadmePreviewTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUXMO_RENDER_README"] == "1"))
    func renderStatisticsPreview() throws {
        let code = try #require(ProcessInfo.processInfo.environment["AUXMO_README_LANGUAGE"])
        try #require(["en", "zh"].contains(code))
        let language: AppLanguage = code == "en" ? .english : .chinese
        let root = try #require(ProcessInfo.processInfo.environment["AUXMO_README_OUTPUT_DIR"])
        let directory = URL(fileURLWithPath: root).appendingPathComponent(code, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let domain = "Auxmo.StatisticsReadme.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 18)))
        let data: [(Int, Int, String, String, String, String, ListeningDeviceKind, Double)] = [
            (-21, 9, "headphones", "AirPods Pro", "bundle:com.apple.Music", "Music", .headphones, 2400),
            (-17, 20, "headphones", "AirPods Pro", "bundle:com.apple.Music", "Music", .headphones, 3600),
            (-12, 10, "speakers", code == "en" ? "MacBook Speakers" : "MacBook 扬声器", "bundle:com.apple.Safari", "Safari", .builtInSpeaker, 1800),
            (-8, 19, "headphones", "AirPods Pro", "bundle:com.apple.Music", "Music", .headphones, 2700),
            (-4, 9, "speakers", code == "en" ? "MacBook Speakers" : "MacBook 扬声器", "bundle:com.apple.Safari", "Safari", .builtInSpeaker, 1500),
            (-1, 21, "headphones", "AirPods Pro", "bundle:com.apple.Music", "Music", .headphones, 3000)
        ]
        let buckets = try data.flatMap { day, hour, uid, device, appID, app, kind, seconds -> [ListeningStatisticsBucket] in
            let dayStart = try #require(calendar.date(byAdding: .day, value: day, to: calendar.startOfDay(for: now)))
            let date = try #require(calendar.date(byAdding: .hour, value: hour, to: dayStart))
            // 每个历史桶最多 15 分钟；长会话拆成多个相邻时间桶。
            return stride(from: 0, to: Int(seconds), by: 900).map { offset in
                ListeningStatisticsBucket(start: date.addingTimeInterval(Double(offset)), deviceUID: uid,
                                          deviceName: device, deviceKind: kind, applicationID: appID,
                                          applicationName: app, seconds: min(900, seconds - Double(offset)))
            }
        }
        defaults.set(try JSONEncoder().encode(buckets), forKey: "com.colin0v0.auxmo.listeningStatistics.v1")
        let statistics = ListeningStatisticsStore(defaults: defaults)
        let host = NSHostingView(rootView: ListeningStatisticsView(statistics: statistics, now: now, calendar: calendar)
            .frame(width: 760).padding(24).environment(\.appLanguage, language).environment(\.colorScheme, .light)
            .foregroundStyle(PanelStyle.ink).background(PanelStyle.canvas))
        host.appearance = NSAppearance(named: .aqua)
        host.frame.size = host.fittingSize
        PanelTestSupport.flushLayout(host)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("statistics.png"))
    }
}
