import Foundation
import CoreAudio
import AuxmoCore

/// 输出设备的统计分类。Core Audio 的传输类型无法准确区分所有 USB 设备，允许用户以后覆盖分类。
enum ListeningDeviceKind: String, Codable, CaseIterable, Sendable {
    case headphones
    case builtInSpeaker
    case externalSpeaker
    case display
    case other

    var title: String {
        switch self {
        case .headphones: return "耳机"
        case .builtInSpeaker: return "内置扬声器"
        case .externalSpeaker: return "外接音响"
        case .display: return "显示器扬声器"
        case .other: return "其他设备"
        }
    }

    static func infer(from output: AudioOutput) -> Self {
        if output.isBluetooth { return .headphones }
        switch output.transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtInSpeaker
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return .display
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: return .externalSpeaker
        default: return .other
        }
    }
}

/// 统计的最小持久化单位。一个时间桶同时记录软件和实际输出设备，便于绘制交叉矩阵。
struct ListeningStatisticsBucket: Codable, Hashable, Sendable {
    let start: Date
    let deviceUID: String
    let deviceName: String
    let deviceKind: ListeningDeviceKind
    let applicationID: String
    let applicationName: String
    var seconds: Double
}

struct ListeningDeviceSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: ListeningDeviceKind
    let seconds: Double
    let lastUsed: Date

    var durationText: String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "\(minutes) 分钟"
    }
}

struct ListeningApplicationSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let seconds: Double
    let lastUsed: Date

    var durationText: String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "\(minutes) 分钟"
    }
}

/// 本机统计存储：只保留 Auxmo 观察到的音频流，不读取或上传健康数据。
@MainActor
final class ListeningStatisticsStore: ObservableObject {
    @Published private(set) var buckets: [ListeningStatisticsBucket] = []

    private static let storageKey = "com.colin0v0.auxmo.listeningStatistics.v1"
    // 新记录按采样片段保存真实时间并集；旧桶无法还原重叠关系，单独保留。
    private struct Interval: Codable {
        let start: Date
        var end: Date
        let devices: [String]
        let applications: [String]
    }
    private static let intervalsKey = "com.colin0v0.auxmo.listeningStatistics.intervals.v2"
    private static let legacyKey = "com.colin0v0.auxmo.listeningStatistics.legacy.v2"
    private var legacyBuckets: [ListeningStatisticsBucket] = []
    private static let migrationKey = "com.colin0v0.auxmo.listeningStatistics.migrationDate.v2"
    private var intervals: [Interval] = []
    private var migrationDate: Date
    private let defaults: UserDefaults
    private var lastSampleAt: Date?
    private var lastPersistAt: Date?
    private let bucketLength: TimeInterval = 15 * 60
    private let sampleInterval: TimeInterval = 15

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let date = defaults.object(forKey: Self.migrationKey) as? Date {
            migrationDate = date
        } else {
            migrationDate = Date()
            defaults.set(migrationDate, forKey: Self.migrationKey)
        }
        if let data = defaults.data(forKey: Self.intervalsKey) {
            intervals = try! JSONDecoder().decode([Interval].self, from: data)
        }
        if let data = defaults.data(forKey: Self.storageKey) {
            // 已存在的统计记录必须保持结构完整；损坏记录直接暴露，不能用空统计掩盖问题。
            buckets = try! JSONDecoder().decode([ListeningStatisticsBucket].self, from: data)
        }
        if let data = defaults.data(forKey: Self.legacyKey) {
            legacyBuckets = try! JSONDecoder().decode([ListeningStatisticsBucket].self, from: data)
        } else {
            legacyBuckets = buckets
            defaults.set(try! JSONEncoder().encode(legacyBuckets), forKey: Self.legacyKey)
        }
    }

    /// 每次应用状态刷新都调用；内部节流到 15 秒，避免高频写入磁盘。
    func record(at now: Date, outputs: [AudioOutput], applications: [ApplicationAudioRow]) {
        guard !outputs.isEmpty, !applications.isEmpty else {
            lastSampleAt = now
            return
        }
        guard let previous = lastSampleAt else {
            lastSampleAt = now
            return
        }
        let elapsed = now.timeIntervalSince(previous)
        guard elapsed >= sampleInterval, elapsed < 120 else {
            if elapsed >= 120 { lastSampleAt = now }
            return
        }
        lastSampleAt = now
        let active = applications.filter(\.isRunningOutput)
        guard !active.isEmpty else { return }
        // 重叠的应用和输出只产生一个时间片，避免整体时长重复累计。
        let deviceIDs = Array(Set(outputs.map(\.uid))).sorted()
        let applicationIDs = Array(Set(active.map(\.id))).sorted()
        // 同一小时内、设备与应用未变化的连续片段合并，限制长期存储增长。
        if let last = intervals.indices.last, intervals[last].end == previous,
           intervals[last].devices == deviceIDs, intervals[last].applications == applicationIDs,
           Calendar.current.isDate(intervals[last].start, equalTo: now, toGranularity: .hour) {
            intervals[last].end = now
        } else {
            intervals.append(Interval(start: previous, end: now, devices: deviceIDs, applications: applicationIDs))
        }
        let bucketStart = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / bucketLength) * bucketLength)
        for output in outputs {
            let kind = ListeningDeviceKind.infer(from: output)
            for application in active {
                let index = buckets.firstIndex {
                    $0.start == bucketStart && $0.deviceUID == output.uid && $0.applicationID == application.id
                }
                if let index {
                    buckets[index].seconds += elapsed
                } else {
                    buckets.append(ListeningStatisticsBucket(start: bucketStart,
                                                             deviceUID: output.uid,
                                                             deviceName: output.name,
                                                             deviceKind: kind,
                                                             applicationID: application.id,
                                                             applicationName: application.label,
                                                             seconds: elapsed))
                }
            }
        }
        if lastPersistAt.map({ now.timeIntervalSince($0) >= 60 }) != false {
            persist()
            lastPersistAt = now
        }
        objectWillChange.send()
    }

    /// 应用与设备按各自的活跃时间统计，允许同时使用，因此各项占比不一定互斥。
    func deviceSummaries(since: Date? = nil) -> [ListeningDeviceSummary] {
        let metadata = Dictionary(grouping: buckets, by: \.deviceUID)
        return metadata.compactMap { uid, rows in
            let old = legacyDimensionSeconds(rows: legacyBuckets.filter { $0.deviceUID == uid }, since: since)
            let recent = intervalSeconds(since: since) { $0.devices.contains(uid) }
            let seconds = old + recent
            guard seconds > 0, let first = rows.first,
                  let last = rows.filter({ since == nil || $0.start >= since! }).map(\.start).max() else { return nil }
            return ListeningDeviceSummary(id: uid, name: first.deviceName, kind: first.deviceKind,
                                          seconds: seconds, lastUsed: last)
        }.sorted { $0.seconds > $1.seconds }
    }

    func applicationSummaries(since: Date? = nil) -> [ListeningApplicationSummary] {
        let metadata = Dictionary(grouping: buckets, by: \.applicationID)
        return metadata.compactMap { id, rows in
            let old = legacyDimensionSeconds(rows: legacyBuckets.filter { $0.applicationID == id }, since: since)
            let recent = intervalSeconds(since: since) { $0.applications.contains(id) }
            let seconds = old + recent
            guard seconds > 0, let first = rows.first,
                  let last = rows.filter({ since == nil || $0.start >= since! }).map(\.start).max() else { return nil }
            return ListeningApplicationSummary(id: id, name: first.applicationName, seconds: seconds, lastUsed: last)
        }.sorted { $0.seconds > $1.seconds }
    }

    private func legacyDimensionSeconds(rows: [ListeningStatisticsBucket], since: Date?) -> Double {
        let selected = rows.filter { since == nil || $0.start >= since! }
        return Dictionary(grouping: selected, by: \.start).values.reduce(0) { total, bucket in
            total + bucket.map(\.seconds).max()!
        }
    }

    private func intervalSeconds(since: Date?, matching: (Interval) -> Bool) -> Double {
        intervals.filter(matching).reduce(0) { result, interval in
            result + max(0, interval.end.timeIntervalSince(max(interval.start, since ?? interval.start)))
        }
    }

    /// 旧数据只有 15 分钟汇总，无法知道各应用是否重叠；每桶取最长记录作为保守估计。
    private func legacyTotals(since: Date?, until: Date?) -> [(Date, Double)] {
        let rows = legacyBuckets.filter { (since == nil || $0.start >= since!) && (until == nil || $0.start < until!) }
        return Dictionary(grouping: rows, by: \.start).map { ($0.key, $0.value.map(\.seconds).max()!) }
    }

    /// 新数据使用实际采样时间片，旧数据保留为估算；支持半开区间以比较前后周期。
    private func totals(since: Date?, until: Date?) -> [(Date, Double)] {
        var result = legacyTotals(since: since, until: until)
        for interval in intervals {
            let start = max(interval.start, since ?? interval.start)
            let end = min(interval.end, until ?? interval.end)
            var cursor = start
            while cursor < end {
                let hourEnd = Calendar.current.dateInterval(of: .hour, for: cursor)!.end
                let segmentEnd = min(end, hourEnd)
                result.append((cursor, segmentEnd.timeIntervalSince(cursor)))
                cursor = segmentEnd
            }
        }
        return result
    }

    /// 合并连续采样片段；旧桶仅能按时间桶间距推算，不能视作精确播放会话。
    func sessionDurations(since: Date? = nil) -> [Double] {
        let pieces = totals(since: since, until: nil).sorted { $0.0 < $1.0 }
        var result: [Double] = []
        var current = 0.0
        var previous: Date?
        for (start, seconds) in pieces {
            if let previous, start.timeIntervalSince(previous) > bucketLength * 2 {
                result.append(current)
                current = 0
            }
            current += seconds
            // 比较片段结束时间，跨整点的连续播放不会被误拆成多次。
            previous = start.addingTimeInterval(seconds)
        }
        if current > 0 { result.append(current) }
        return result
    }

    func sessionCount(since: Date? = nil) -> Int { sessionDurations(since: since).count }
    func averageSessionSeconds(since: Date? = nil) -> Double {
        let values = sessionDurations(since: since)
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
    func longestSessionSeconds(since: Date? = nil) -> Double { sessionDurations(since: since).max() ?? 0 }
    func activeDayCount(since: Date? = nil, calendar: Calendar = .current) -> Int {
        dailyTotals(since: since, calendar: calendar).count
    }
    func dailyTotals(since: Date? = nil, calendar: Calendar = .current) -> [Date: Double] {
        Dictionary(grouping: totals(since: since, until: nil), by: { calendar.startOfDay(for: $0.0) })
            .mapValues { $0.reduce(0) { $0 + $1.1 } }
    }
    func totalSeconds(since: Date? = nil, until: Date? = nil) -> Double {
        totals(since: since, until: until).reduce(0) { $0 + $1.1 }
    }
    /// 返回星期 × 小时的分钟数，数据按实际时间片去重。
    func heatmap(since: Date? = nil, calendar: Calendar = .current) -> [[Double]] {
        var result = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        for (date, seconds) in totals(since: since, until: nil) {
            let weekday = (calendar.component(.weekday, from: date) + 5) % 7
            result[weekday][calendar.component(.hour, from: date)] += seconds / 60
        }
        return result
    }

    func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(buckets)
        defaults.set(data, forKey: Self.storageKey)
        defaults.set(try! encoder.encode(intervals), forKey: Self.intervalsKey)
    }
}
