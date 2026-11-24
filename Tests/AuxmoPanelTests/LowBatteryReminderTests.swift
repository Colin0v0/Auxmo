import Foundation
import UserNotifications
import Testing
import AuxmoCore
@testable import Auxmo

struct LowBatteryReminderTests {
    @Test @MainActor func enablingRequiresAlertPermissionEveryTime() async throws {
        let domain = "auxmo.low-battery-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        var allowed = false
        var checks = 0
        let access = BatteryNotificationAccess(status: { .denied }, request: { false },
                                               hasAlertPermission: { checks += 1; return allowed })
        let reminder = LowBatteryReminder(settings: settings, access: access)
        #expect(settings.lowBatteryReminderEnabled == false)
        reminder.setEnabled(true)
        for _ in 0..<20 where reminder.isRequesting { await Task.yield() }
        #expect(settings.lowBatteryReminderEnabled == false)
        #expect(reminder.permissionMessage != nil)
        allowed = true
        reminder.setEnabled(true)
        for _ in 0..<20 where reminder.isRequesting { await Task.yield() }
        #expect(settings.lowBatteryReminderEnabled == true)
        reminder.setEnabled(false)
        allowed = false
        reminder.setEnabled(true)
        for _ in 0..<20 where reminder.isRequesting { await Task.yield() }
        #expect(settings.lowBatteryReminderEnabled == false)
        #expect(checks == 3)
    }

    @Test @MainActor func firstEnableRequestsPermissionAndKeepsSwitchOffWhenDenied() async throws {
        let domain = "auxmo.low-battery-first.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        var grants = false
        var requests = 0
        let access = BatteryNotificationAccess(status: { .notDetermined },
            request: { requests += 1; return grants }, hasAlertPermission: { grants })
        let reminder = LowBatteryReminder(settings: settings, access: access)
        reminder.setEnabled(true)
        for _ in 0..<20 where reminder.isRequesting { await Task.yield() }
        #expect(requests == 1)
        #expect(settings.lowBatteryReminderEnabled == false)
        grants = true
        reminder.setEnabled(true)
        for _ in 0..<20 where reminder.isRequesting { await Task.yield() }
        #expect(requests == 2)
        #expect(settings.lowBatteryReminderEnabled == true)
    }

    @Test func thresholdAndRepeatBehaviorArePerDevice() {
        var policy = LowBatteryReminderPolicy()
        #expect(policy.shouldNotify(device: "a", reading: .init(single: 21)) == nil)
        #expect(policy.shouldNotify(device: "a", reading: .init(single: 20)) == 20)
        #expect(policy.shouldNotify(device: "a", reading: .init(single: 19)) == nil)
        #expect(policy.shouldNotify(device: "b", reading: .init(left: 25, right: 18)) == 18)
        #expect(policy.shouldNotify(device: "a", reading: .init(single: 30)) == nil)
        #expect(policy.shouldNotify(device: "a", reading: .init(single: 19)) == 19)
    }

    @Test func ignoresUnknownAndCaseOnlyReadings() {
        var policy = LowBatteryReminderPolicy()
        #expect(policy.shouldNotify(device: "a", reading: .init(caseLevel: 5)) == nil)
        #expect(policy.shouldNotify(device: "a", reading: .init(single: -1)) == nil)
        #expect(policy.shouldNotify(device: "charging", reading: .init(single: 10, isCharging: true)) == 10)
        #expect(policy.shouldNotify(device: "a", reading: .init(left: 15, right: nil)) == 15)
        policy.deliveryFailed(device: "a")
        #expect(policy.shouldNotify(device: "a", reading: .init(left: 15)) == 15)
    }
}
