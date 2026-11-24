import AppKit
import Combine
import Foundation
import UserNotifications
import AuxmoCore

/// 一副耳机低于阈值只提醒一次；回升后再次降低才进入下一轮。
struct LowBatteryReminderPolicy {
    private(set) var alerted: Set<String> = []
    let threshold = 20

    mutating func shouldNotify(device: String, reading: HeadphoneBatteryReading) -> Int? {
        // 充电盒不代表耳机电量，未知部件也不能当成 0%。
        let values = [reading.single, reading.left, reading.right].compactMap { $0 }.filter { (0...100).contains($0) }
        guard let level = values.min() else { return nil }
        if level > threshold { alerted.remove(device); return nil }
        guard !alerted.contains(device) else { return nil }
        alerted.insert(device)
        return level
    }

    mutating func deliveryFailed(device: String) { alerted.remove(device) }
    mutating func reset() { alerted.removeAll() }
}

/// 授权查询与请求可独立替换，便于验证拒绝、再次开启和异步竞态。
@MainActor
struct BatteryNotificationAccess {
    var status: () async -> UNAuthorizationStatus
    var request: () async throws -> Bool
    var hasAlertPermission: () async -> Bool

    static var live: Self {
        Self(status: { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus },
             request: { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) },
             hasAlertPermission: {
                let state = await UNUserNotificationCenter.current().notificationSettings()
                return state.authorizationStatus == .authorized && state.alertSetting == .enabled
             })
    }
}

/// 只在应用运行期间监听真实设备上报，通知由系统通知中心呈现。
@MainActor
final class LowBatteryReminder: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = LowBatteryReminder(settings: .shared)
    private let settings: AppSettings
    private let access: BatteryNotificationAccess
    // 延迟获取通知中心：SwiftPM 测试宿主没有应用 bundle，不能在构造设置页面时访问。
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    private var group: HeadphoneControllerGroup?
    private var subscriptions = Set<AnyCancellable>()
    private var policy = LowBatteryReminderPolicy()
    @Published private(set) var isRequesting = false
    @Published var permissionMessage: String?
    private var enableGeneration = 0

    convenience init(settings: AppSettings) {
        self.init(settings: settings, access: .live)
    }

    init(settings: AppSettings, access: BatteryNotificationAccess) {
        self.settings = settings
        self.access = access
        super.init()
    }

    // 即使详情窗口在前台，也允许系统以横幅显示低电量通知。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification,
                                             withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func start(group: HeadphoneControllerGroup) {
        self.group = group
        center.delegate = self
        // 控制器发的是 willChange；切到下一次主队列读取更新后的电量。
        group.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkReadings() }
        }.store(in: &subscriptions)
        checkReadings()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled && isRequesting { return }
        enableGeneration += 1
        let generation = enableGeneration
        if !enabled {
            settings.lowBatteryReminderEnabled = false
            policy.reset()
            isRequesting = false
            return
        }
        permissionMessage = nil
        isRequesting = true
        Task { @MainActor in
            defer { if generation == enableGeneration { isRequesting = false } }
            let status = await access.status()
            var requestError: String?
            if status == .notDetermined {
                do { _ = try await access.request() }
                catch { requestError = error.localizedDescription }
            }
            let authorized = await access.hasAlertPermission()
            guard generation == enableGeneration else { return }
            guard authorized else {
                settings.lowBatteryReminderEnabled = false
                permissionMessage = requestError ?? settings.localized("请在系统设置中允许 Auxmo 发送通知。")
                return
            }
            settings.lowBatteryReminderEnabled = true
            checkReadings()
        }
    }

    func recheckPermission() {
        guard settings.lowBatteryReminderEnabled == true else { return }
        let generation = enableGeneration
        Task { @MainActor in
            let authorized = await access.hasAlertPermission()
            guard generation == enableGeneration else { return }
            if !authorized {
                settings.lowBatteryReminderEnabled = false
                policy.reset()
            }
        }
    }

    private func checkReadings() {
        guard settings.lowBatteryReminderEnabled == true, let group else { return }
        for entry in group.entries {
            guard entry.controller.phase == .ready, let reading = entry.controller.state.battery,
                  let level = policy.shouldNotify(device: entry.id, reading: reading) else { continue }
            let content = UNMutableNotificationContent()
            content.title = settings.localized("耳机电量低")
            content.body = settings.localizedFormat("%@ 电量为 %d%%，请充电。", entry.output.name, level)
            content.sound = .default
            let request = UNNotificationRequest(identifier: "low-battery-\(UUID().uuidString)", content: content, trigger: nil)
            let generation = enableGeneration
            Task { @MainActor in
                let authorized = await access.hasAlertPermission()
                guard generation == enableGeneration else { return }
                guard authorized, settings.lowBatteryReminderEnabled == true else {
                    policy.deliveryFailed(device: entry.id)
                    if !authorized { settings.lowBatteryReminderEnabled = false }
                    return
                }
                do { try await center.add(request) }
                catch { policy.deliveryFailed(device: entry.id) }
            }
        }
    }

    func openNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
