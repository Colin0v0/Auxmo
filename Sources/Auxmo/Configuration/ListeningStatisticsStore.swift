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

/// 详情页筛选的对象；所有指标共享同一筛选口径。
enum ListeningStatisticsScope: Hashable {
    case device(String)
    case application(String)

    func matches(_ bucket: ListeningStatisticsBucket) -> Bool {
        switch self {
        case .device(let id): return bucket.deviceUID == id
        case .application(let id): return bucket.applicationID == id
        }
    }
}

/// 一次采样中某个应用实际确认的输出设备。
struct ListeningPlaybackObservation {
    let application: ApplicationAudioRow
    let outputs: [AudioOutput]
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
        // nil 是旧版按所有应用 × 设备记录的历史片段，无法还原真实配对。
        let applicationDevices: [String: [String]]?
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

    /// 每次应用状态刷新都调用；每条观察携带该应用实际确认的输出。
    func record(at now: Date, observations: [ListeningPlaybackObservation]) {
        let active = observations.filter { $0.application.isRunningOutput && !$0.outputs.isEmpty }
        // 没有可确认的播放时刻持续更新采样基点，恢复时不能把空闲时间算进去。
        guard !active.isEmpty else { lastSampleAt = now; return }
        guard let previous = lastSampleAt else { lastSampleAt = now; return }
        let elapsed = now.timeIntervalSince(previous)
        guard elapsed >= sampleInterval, elapsed < 120 else {
            if elapsed >= 120 { lastSampleAt = now }
            return
        }
        lastSampleAt = now
        var routes: [String: [String]] = [:]
        for observation in active {
            routes[observation.application.id] = Array(Set(observation.outputs.map(\.uid))).sorted()
        }
        let applicationIDs = routes.keys.sorted()
        let deviceIDs = Array(Set(routes.values.flatMap { $0 })).sorted()
        // 只有应用与设备配对完全一致的连续片段才能合并。
        if let last = intervals.indices.last, intervals[last].end == previous,
           intervals[last].applicationDevices == routes,
           Calendar.current.isDate(intervals[last].start, equalTo: now, toGranularity: .hour) {
            intervals[last].end = now
        } else {
            intervals.append(Interval(start: previous, end: now, devices: deviceIDs,
                                      applications: applicationIDs, applicationDevices: routes))
        }
        let bucketStart = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / bucketLength) * bucketLength)
        for observation in active {
            for output in observation.outputs {
                let application = observation.application
                let index = buckets.firstIndex {
                    $0.start == bucketStart && $0.deviceUID == output.uid && $0.applicationID == application.id
                }
                if let index {
                    buckets[index].seconds += elapsed
                } else {
                    buckets.append(ListeningStatisticsBucket(start: bucketStart, deviceUID: output.uid,
                        deviceName: output.name, deviceKind: ListeningDeviceKind.infer(from: output),
                        applicationID: application.id, applicationName: application.label, seconds: elapsed))
                }
            }
        }
        if lastPersistAt.map({ now.timeIntervalSince($0) >= 60 }) != false {
            persist()
            lastPersistAt = now
        }
        objectWillChange.send()
    }

    /// 确认全部应用共享同一输出的采样入口。
    func record(at now: Date, outputs: [AudioOutput], applications: [ApplicationAudioRow]) {
        record(at: now, observations: applications.map { ListeningPlaybackObservation(application: $0, outputs: outputs) })
    }

    /// 应用与设备按各自的活跃时间统计，允许同时使用，因此各项占比不一定互斥。
    func deviceSummaries(since: Date? = nil, scope: ListeningStatisticsScope? = nil) -> [ListeningDeviceSummary] {
        let metadata = Dictionary(grouping: buckets, by: \.deviceUID)
        return metadata.compactMap { uid, rows in
            let old = legacyDimensionSeconds(rows: legacyBuckets.filter { $0.deviceUID == uid && (scope == nil || scope!.matches($0)) }, since: since)
            let recent = intervalSeconds(since: since) { interval in
                guard interval.devices.contains(uid), matches(interval, scope: scope) else { return false }
                if case .application(let app) = scope { return containsPair(interval, application: app, device: uid) }
                return true
            }
            let seconds = old + recent
            guard seconds > 0, let first = rows.first,
                  let last = rows.filter({ since == nil || $0.start >= since! }).map(\.start).max() else { return nil }
            return ListeningDeviceSummary(id: uid, name: first.deviceName, kind: first.deviceKind,
                                          seconds: seconds, lastUsed: last)
        }.sorted { $0.seconds > $1.seconds }
    }

    func applicationSummaries(since: Date? = nil, scope: ListeningStatisticsScope? = nil) -> [ListeningApplicationSummary] {
        let metadata = Dictionary(grouping: buckets, by: \.applicationID)
        return metadata.compactMap { id, rows in
            let old = legacyDimensionSeconds(rows: legacyBuckets.filter { $0.applicationID == id && (scope == nil || scope!.matches($0)) }, since: since)
            let recent = intervalSeconds(since: since) { interval in
                guard interval.applications.contains(id), matches(interval, scope: scope) else { return false }
                if case .device(let uid) = scope { return containsPair(interval, application: id, device: uid) }
                return true
            }
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

    private func containsPair(_ interval: Interval, application: String, device: String) -> Bool {
        if let routes = interval.applicationDevices { return routes[application]?.contains(device) == true }
        // 旧版只有两个集合，保留原有历史估算；不把它标记为新采样的精确配对。
        return interval.applications.contains(application) && interval.devices.contains(device)
    }

    private func matches(_ interval: Interval, scope: ListeningStatisticsScope?) -> Bool {
        switch scope {
        case .device(let id): return interval.devices.contains(id)
        case .application(let id): return interval.applications.contains(id)
        case nil: return true
        }
    }

    /// 首次记录以保存的时间为准；不推断软件安装前的数据。
    func firstRecordedDate(scope: ListeningStatisticsScope? = nil) -> Date? {
        let legacy = legacyBuckets.filter { scope == nil || scope!.matches($0) }.map(\.start)
        let recent = intervals.filter { matches($0, scope: scope) }.map(\.start)
        return (legacy + recent).min()
    }

    /// 旧数据只有 15 分钟汇总，无法知道各应用是否重叠；每桶取最长记录作为保守估计。
    private func legacyTotals(since: Date?, until: Date?, scope: ListeningStatisticsScope?) -> [(Date, Double)] {
        let rows = legacyBuckets.filter { (scope == nil || scope!.matches($0)) && (since == nil || $0.start >= since!) && (until == nil || $0.start < until!) }
        return Dictionary(grouping: rows, by: \.start).map { ($0.key, $0.value.map(\.seconds).max()!) }
    }

    /// 新数据使用实际采样时间片，旧数据保留为估算；支持半开区间以比较前后周期。
    private func totals(since: Date?, until: Date?, scope: ListeningStatisticsScope? = nil) -> [(Date, Double)] {
        var result = legacyTotals(since: since, until: until, scope: scope)
        for interval in intervals where matches(interval, scope: scope) {
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
    func sessionDurations(since: Date? = nil, scope: ListeningStatisticsScope? = nil) -> [Double] {
        let pieces = totals(since: since, until: nil, scope: scope).sorted { $0.0 < $1.0 }
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
    func dailyTotals(since: Date? = nil, calendar: Calendar = .current, scope: ListeningStatisticsScope? = nil) -> [Date: Double] {
        Dictionary(grouping: totals(since: since, until: nil, scope: scope), by: { calendar.startOfDay(for: $0.0) })
            .mapValues { $0.reduce(0) { $0 + $1.1 } }
    }
    func totalSeconds(since: Date? = nil, until: Date? = nil, scope: ListeningStatisticsScope? = nil) -> Double {
        totals(since: since, until: until, scope: scope).reduce(0) { $0 + $1.1 }
    }
    /// 返回星期 × 小时的分钟数，数据按实际时间片去重。
    func heatmap(since: Date? = nil, calendar: Calendar = .current, scope: ListeningStatisticsScope? = nil) -> [[Double]] {
        var result = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        for (date, seconds) in totals(since: since, until: nil, scope: scope) {
            let weekday = (calendar.component(.weekday, from: date) + 5) % 7
            result[weekday][calendar.component(.hour, from: date)] += seconds / 60
        }
        return result
    }

    /// 导出包含历史桶和去重采样片段，不只导出界面上看到的汇总。
    func exportData() throws -> Data {
        struct Archive: Encodable {
            let formatVersion: Int
            let exportedAt: Date
            let buckets: [ListeningStatisticsBucket]
            let legacyBuckets: [ListeningStatisticsBucket]
            let intervals: [Interval]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Archive(formatVersion: 3, exportedAt: Date(), buckets: buckets,
                                          legacyBuckets: legacyBuckets, intervals: intervals))
    }

    /// 清除所有统计数据并重置采样基点，防止清除前的时间被重新计入。
    func clearAll() throws {
        // 先编码空历史快照，成功后才变更内存和持久化状态。
        let emptyLegacy = try JSONEncoder().encode([ListeningStatisticsBucket]())
        buckets.removeAll()
        intervals.removeAll()
        legacyBuckets.removeAll()
        lastSampleAt = nil
        lastPersistAt = nil
        defaults.removeObject(forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.intervalsKey)
        defaults.set(emptyLegacy, forKey: Self.legacyKey)
    }

    func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(buckets)
        defaults.set(data, forKey: Self.storageKey)
        defaults.set(try! encoder.encode(intervals), forKey: Self.intervalsKey)
    }
}
