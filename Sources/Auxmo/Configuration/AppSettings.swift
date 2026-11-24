import AppKit
import CoreFoundation
import Combine
import SwiftUI
import AuxmoCore

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    /// 跟随系统时只区分中文与其他语言；当前产品只提供中英两套文案。
    func resolved(systemLanguage: String = Locale.preferredLanguages.first ?? "en") -> AppLanguage {
        switch self {
        case .chinese, .english: return self
        case .system:
            return systemLanguage.lowercased().hasPrefix("zh") ? .chinese : .english
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 设置只保存用户明确选择的产品项；读取失败不使用另一套业务路径。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let language = "com.colin0v0.auxmo.settings.language"
        static let appearance = "com.colin0v0.auxmo.settings.appearance"
        static let headphones = "com.colin0v0.auxmo.settings.showHeadphones"
        static let simultaneousOutput = "com.colin0v0.auxmo.settings.showSimultaneousOutput"
        static let appAudioEffects = "com.colin0v0.auxmo.settings.appAudioEffectsEnabled"
        static let menuBarBatterySource = "com.colin0v0.auxmo.settings.menuBarBatterySource"
        static let lowBatteryReminder = "com.colin0v0.auxmo.settings.lowBatteryReminder"
        static let menuBarDeviceIcon = "com.colin0v0.auxmo.settings.menuBarDeviceIcon"
        static let legacyCurrentDeviceBattery = "com.colin0v0.auxmo.settings.showCurrentDeviceBattery"
    }

    private let defaults: UserDefaults

    /// nil 明确表示记录不可读，不冒充用户已选择默认值；只有用户再次选择才覆盖该键。
    @Published private(set) var readErrors: [String: String] = [:]
    @Published var language: AppLanguage? { didSet { persist(language?.rawValue, key: Key.language) } }
    @Published var appearance: AppAppearance? {
        didSet { persist(appearance?.rawValue, key: Key.appearance); applyApplicationAppearance() }
    }
    @Published var showHeadphoneControls: Bool? { didSet { persist(showHeadphoneControls, key: Key.headphones) } }
    @Published var showSimultaneousOutput: Bool? { didSet { persist(showSimultaneousOutput, key: Key.simultaneousOutput) } }
    @Published var appAudioEffectsEnabled: Bool? { didSet { persist(appAudioEffectsEnabled, key: Key.appAudioEffects) } }
    @Published var menuBarBatterySource: MenuBarBatterySource? { didSet { persist(menuBarBatterySource?.storageValue, key: Key.menuBarBatterySource) } }
    @Published var lowBatteryReminderEnabled: Bool? { didSet { persist(lowBatteryReminderEnabled, key: Key.lowBatteryReminder) } }
    @Published var showMenuBarDeviceIcon: Bool? { didSet { persist(showMenuBarDeviceIcon, key: Key.menuBarDeviceIcon) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var errors: [String: String] = [:]
        language = Self.read(defaults, key: Key.language, initial: .system, errors: &errors) {
            guard let raw = $0 as? String else { return nil }; return AppLanguage(rawValue: raw)
        }
        appearance = Self.read(defaults, key: Key.appearance, initial: .system, errors: &errors) {
            guard let raw = $0 as? String else { return nil }; return AppAppearance(rawValue: raw)
        }
        showHeadphoneControls = Self.read(defaults, key: Key.headphones, initial: false, errors: &errors, decode: Self.boolean)
        showSimultaneousOutput = Self.read(defaults, key: Key.simultaneousOutput, initial: false, errors: &errors, decode: Self.boolean)
        appAudioEffectsEnabled = Self.read(defaults, key: Key.appAudioEffects, initial: false, errors: &errors, decode: Self.boolean)
        lowBatteryReminderEnabled = Self.read(defaults, key: Key.lowBatteryReminder, initial: false, errors: &errors, decode: Self.boolean)
        showMenuBarDeviceIcon = Self.read(defaults, key: Key.menuBarDeviceIcon, initial: false, errors: &errors, decode: Self.boolean)
        if defaults.object(forKey: Key.menuBarBatterySource) != nil {
            // 新记录存在就只能解析新记录；损坏时不读旧键，更不能写回迁移结果。
            menuBarBatterySource = Self.read(defaults, key: Key.menuBarBatterySource, initial: .off, errors: &errors) {
                guard let raw = $0 as? String else { return nil }; return MenuBarBatterySource(storageValue: raw)
            }
        } else if let legacy = defaults.object(forKey: Key.legacyCurrentDeviceBattery) {
            if let enabled = Self.boolean(legacy) {
                let migrated: MenuBarBatterySource = enabled ? .currentOutput : .off
                menuBarBatterySource = migrated
                defaults.set(migrated.storageValue, forKey: Key.menuBarBatterySource)
            } else {
                menuBarBatterySource = nil
                errors[Key.menuBarBatterySource] = Key.legacyCurrentDeviceBattery
            }
        } else { menuBarBatterySource = .off }
        readErrors = errors
    }

    private static func read<Value>(_ defaults: UserDefaults, key: String, initial: Value,
                                    errors: inout [String: String], decode: (Any) -> Value?) -> Value? {
        guard let raw = defaults.object(forKey: key) else { return initial }
        guard let value = decode(raw) else { errors[key] = key; return nil }
        return value
    }

    private static func boolean(_ raw: Any) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func persist(_ value: Any?, key: String) {
        guard let value else { return }
        defaults.set(value, forKey: key)
        readErrors.removeValue(forKey: key)
    }

    var resolvedLanguage: AppLanguage {
        // 设置损坏时没有已选语言。这里只决定如何绘制错误界面，不把系统语言写成已恢复的配置。
        guard let language else { return AppLanguage.system.resolved() }
        return language.resolved()
    }

    func localized(_ key: String) -> String {
        L10n.text(key, language: resolvedLanguage)
    }

    func localizedFormat(_ format: String, _ arguments: CVarArg...) -> String {
        L10n.format(format, language: resolvedLanguage, arguments: arguments)
    }

    func applyApplicationAppearance() {
        NSApp?.appearance = appearance?.nsAppearance
    }
}

/// 文案直接内置在可执行文件中，避免 Swift Package 资源包未复制时出现“设置有效但界面没翻译”的半成品。
enum L10n {
    static func text(_ key: String, language: AppLanguage) -> String {
        guard language == .english else { return key }
        return english[key] ?? key
    }

    static func format(_ format: String, language: AppLanguage, arguments: [CVarArg]) -> String {
        let template = text(format, language: language)
        return String(format: template, locale: Locale(identifier: language == .english ? "en_US" : "zh_CN"),
                      arguments: arguments)
    }

    private static let english: [String: String] = [
        "低电量提醒": "Low Battery Alert",
        "耳机电量降至 20% 时发送通知。": "Notify when headphone battery reaches 20%.",
        "耳机电量低": "Headphone Battery Low",
        "%@ 电量为 %d%%，请充电。": "%@ battery is at %d%%. Please charge it.",
        "通知权限未开启": "Notifications Are Disabled",
        "请在系统设置中允许 Auxmo 发送通知。": "Allow Auxmo notifications in System Settings.",
        "使用": "Use", "观测": "Insights", "常规": "General", "统计": "Statistics",
        "收起侧边栏": "Hide Sidebar", "展开侧边栏": "Show Sidebar",
        "全部静音": "Mute All",
        "仅静音 Auxmo 已接管的应用。新播放应用可能短暂出声，不包含系统提示音。":
            "Mutes apps managed by Auxmo only. Newly playing apps may be heard briefly; system sounds are not included.",
        "恢复各 App 原有静音状态": "Restore Each App's Mute State",
        "全局安全静音已开启": "Global safety mute is on",
        "全局安全静音已关闭": "Global safety mute is off",
        "关闭后恢复各 App 原有静音状态": "Turn off to restore each app's mute state.",
        "所选输出不可用，已暂停播放": "Selected output unavailable. Playback paused.",
        "所选输出当前不可用": "Selected output unavailable.",
        "%d 台所选设备当前不可用": "%d selected output(s) unavailable",
        "左 %d%%": "L %d%%",
        "右 %d%%": "R %d%%",
        "盒 %d%%": "Case %d%%",
        "正在切换音频路由…": "Switching the audio route…",
        "未佩戴，戴回后恢复控制": "Not worn. Controls resume when worn again.",
        "等待佩戴": "Waiting to be worn",
        "Apple 耳机拒绝了本次模式切换，当前模式已重新读取；请确认佩戴状态后再操作":
            "The headphones rejected this mode change. The actual mode was read again. Check that they are worn before trying again.",
        "已选设备均暂不可用，等待原设备恢复": "All selected devices are temporarily unavailable. Waiting for them to return.",
        "部分设备暂不可用，正通过其余已选设备播放；恢复后自动加入":
            "Playing through the remaining selected devices. Unavailable members will rejoin when they return.",
        "没有已连接且支持控制的耳机": "No supported headphones connected",
        "耳机已断开或不再是蓝牙输出设备": "Headphones disconnected or no longer available as a Bluetooth output",
        "耳机设备已移除，停止向旧控制目标发送数据": "Headphones removed; control commands have stopped",
        "请先连接支持控制的 B&W 耳机": "Connect supported B&W headphones first",
        "控制的耳机": "Headphone to control",
        "启用耳机控制": "Enable headphone controls",
        "停止控制": "Stop controlling",
        "耳机控制已暂停": "Headphone controls paused",
        "选择要控制的耳机": "Select a headphone to control",
        "当前仅支持原生 Float32 单声道或双声道 PCM；未启用音频接管": "Only native Float32 mono or stereo PCM is supported; audio processing was not enabled.",
        "正在等待系统确认输出…": "Waiting for macOS to confirm the output…",
        "实际输出：%@": "Actual output: %@",
        "提示音输出：%@": "Sound effects output: %@",
        "媒体与提示音输出不一致，请明确选择输出设备": "Media and sound effects use different outputs. Select an output explicitly.",
        "路由仍在等待系统确认，请稍后重新应用": "Waiting for output confirmation. Apply again once it completes.",
        "请先选择一台真实输出设备，再重新应用": "Select a physical output before applying again.",
        "已请求离开旧组合": "Requested departure from the previous group",
        "已确认离开旧组合": "Confirmed departure from the previous group",
        "已释放旧组合": "Released the previous group",
        "已创建并校验新组合": "Created and validated the new group",
        "已请求目标输出": "Requested the target output",
        "已确认目标输出": "Confirmed the target output",
        "已按真实播放通道恢复被抢占的默认输出": "Restored the preempted default output to the real playback route",
        "系统默认输出被反复抢占；Auxmo 已跟随真实输出并停止争抢。若为 AirPods，请在蓝牙设置中把“连接到此 Mac”改为“上次连接此 Mac 时”。":
            "The system default output keeps being taken over. Auxmo followed the real output and stopped fighting for it. For AirPods, set “Connect to This Mac” to “When Last Connected to This Mac” in Bluetooth settings.",
        "系统未在期限内确认媒体与提示音输出": "macOS did not confirm both output routes before the deadline",
        "系统未在期限内释放组合设备，请重试释放": "macOS did not confirm group removal before the deadline. Retry cleanup.",
        "系统未在期限内释放残留组合，请重试释放": "macOS did not confirm removal of the remaining group before the deadline. Retry cleanup.",
        "系统输出已在 Auxmo 外改变；未自动抢回，请确认实际输出后重新选择": "Output changed outside Auxmo. It was not switched back; verify the actual output and select again.",
        "应用未在期限内跟随已确认输出，请重新应用": "The app did not follow the confirmed output before the deadline. Apply again.",
        "请先手动退出 FineTune，避免重复处理音频。":
            "Quit FineTune manually first to avoid processing the same audio twice.",
        "FineTune 已退出，音量配置尚未应用。":
            "FineTune quit before the volume configuration was applied.",
        "系统输出已改变；点重新应用后才会在新设备上处理。":
            "The system output changed. Reapply before processing on the new device.",
        "设置": "Settings",
        "Auxmo 设置": "Auxmo Settings",
        "通用": "General",
        "开机启动": "Launch at Login",
        "登录 Mac 后自动运行 Auxmo。": "Start Auxmo when you log in.",
        "无法更改开机启动": "Could Not Change Launch at Login",
        "好": "OK",
        "语言": "Language",
        "界面语言": "Interface Language",
        "跟随系统": "System",
        "简体中文": "Chinese",
        "浅色": "Light",
        "深色": "Dark",
        "外观": "Appearance",
        "功能": "Features",
        "诊断": "Diagnostics",
        "错误日志": "Error Log",
        "导出音频状态与错误日志。": "Export audio state and error logs.",
        "导出诊断报告…": "Export Diagnostics…",
        "打开 GitHub 项目主页": "Open GitHub Project",
        "GitHub 项目主页": "GitHub Project",
        "无法导出诊断报告": "Could Not Export Diagnostics",
        "导出 Auxmo 诊断报告": "Export Auxmo Diagnostics",
        "报告包含当前音频状态和近期错误，不包含音频内容。":
            "The report contains current audio state and recent errors. Audio is never included.",
        "耳机控制": "Headphones",
        "显示耳机控制页": "Show Headphone Controls",
        "关闭后，耳机控制从主面板隐藏。": "Show the Headphones tab.",
        "显示多设备输出": "Show Multi-Device Output",
        "关闭后，多设备输出功能从输出面板隐藏。":
            "Show multi-device output options.",
        "菜单栏设备图标": "Menu Bar Device Icon",
        "开启后，图标会显示当前使用的电脑、耳机或显示器。":
            "Shows the current computer, headphones, or display.",
        "菜单栏电量": "Menu Bar Battery",
        "固定设备断开后隐藏。": "Pinned devices hide when offline.",
        "不显示": "Don't Show",
        "跟随当前输出": "Follow Current Output",
        "固定：%@": "Pinned: %@",
        "固定设备（未连接）": "Pinned Device (Disconnected)",
        "左键打开/收起，右键更多操作": "Left-click to open or close; right-click for more.",
        "输出": "Output",
        "麦克风": "Microphone",
        "音频控制": "Audio Control",
        "更多操作": "More",
        "控制区域": "Control Sections",
        "打开 Auxmo": "Open Auxmo",
        "设置…": "Settings…",
        "立即刷新": "Refresh Now",
        "更新": "Update",
        "正在下载 %d%%": "Downloading %d%%",
        "正在下载…": "Downloading…",
        "更新中…": "Updating…",
        "进行中": "In Progress",
        "发现新版本 %@": "Version %@ is available",
        "打开更新 %@": "Open Update %@",
        "跳过 %@": "Skip %@",
        "下载中": "Downloading",
        "准备中": "Preparing",
        "重启以更新": "Restart to Update",
        "重试更新": "Retry Update",
        "更新到 %@ 失败：%@": "Update to %@ failed: %@",
        "正在下载更新 %@ · %d%%": "Downloading update %@ · %d%%",
        "正在下载更新 %@…": "Downloading update %@…",
        "正在准备更新 %@…": "Preparing update %@…",
        "重启以更新到 %@": "Restart to Update to %@",
        "检查更新…": "Check for Updates…",
        "检查更新": "Check for Updates",
        "未发现新版本": "No Updates Available",
        "正在检查更新…": "Checking for Updates…",
        "正在检查…": "Checking…",
        "检查失败，重试": "Check Failed, Retry",
        "检查 GitHub 上的 Auxmo 更新": "Check GitHub for Auxmo updates",
        "更新到 %@": "Update to %@",
        "音频录制权限…": "Audio Recording Permission…",
        "未允许系统音频录制，App 音量、电平和路由暂不可用":
            "System audio recording is not allowed. App volume, levels, and routing are unavailable.",
        "请允许系统音频录制，以使用 App 音量、电平和路由":
            "Allow system audio recording to use app volume, levels, and routing.",
        "无法检查系统音频录制权限，App 音频控制已暂停":
            "Cannot check system audio recording permission. App audio controls are paused.",
        "已允许系统音频录制": "System audio recording is allowed",
        "系统音频录制尚未授权": "System audio recording is not authorized",
        "允许访问": "Allow Access",
        "打开系统设置": "Open System Settings",
        "需要系统音频录制权限": "System Audio Recording Permission Required",
        "开启系统录音": "Enable System Audio Recording",
        "自动重启失败": "Automatic Restart Failed",
        "系统音频授权请求接口不可用": "The system audio permission request API is unavailable",
        "系统音频授权请求仍在等待用户决定": "Waiting for the system audio permission decision",
        "在系统设置的“仅系统录音”中开启 Auxmo，用于应用音量、电平和音频路由。开启后 Auxmo 会自动重启。":
            "Enable Auxmo under System Audio Recording Only in System Settings for app volume, levels, and routing. Auxmo will restart automatically after access is granted.",
        "App 音频控制已暂停。请检查系统权限，Auxmo 确认授权后会自动重启。":
            "App audio controls are paused. Check system permissions; Auxmo will restart automatically once access is confirmed.",
        "重启组件不可用，Auxmo 未退出": "The restart helper is unavailable. Auxmo has not quit.",
        "请在系统设置中允许 Auxmo 录制系统音频，以使用应用音量、电平和音频路由。授权后若系统要求重新打开 Auxmo，请按系统提示操作。":
            "Allow Auxmo to record system audio in System Settings to use app volume, levels, and audio routing. If macOS asks you to reopen Auxmo after granting access, follow its instructions.",
        "Auxmo 需要系统音频录制权限才能调节应用音量、显示电平和控制应用输出。请在系统设置中开启 Auxmo，然后重新打开应用。":
            "Auxmo needs System Audio Recording access to control app volume, levels, and output. Enable Auxmo in System Settings, then reopen Auxmo.",
        "重新检查": "Check Again",
        "无法检查系统音频录制权限": "Cannot Check System Audio Recording Permission",
        "App 音频控制已暂停，请检查系统权限后重新打开 Auxmo。":
            "App audio controls are paused. Check system permissions, then reopen Auxmo.",
        "未能打开系统设置，请手动进入隐私与安全性 → 屏幕与系统音频录制。":
            "Could not open System Settings. Open Privacy & Security → Screen & System Audio Recording manually.",
        "复制耳机诊断": "Copy Headphone Diagnostics",
        "退出 Auxmo": "Quit Auxmo",
        "重新读取路由配置": "Reload routing configuration",
        "重新读取预设": "Reload presets",
        "音效预设无法读取，请检查本地设置": "Effect presets could not be read. Check local settings.",
        "音效预设无法保存，请检查本地设置": "Effect presets could not be saved. Check local settings.",
        "重新读取音效配置": "Reload effects configuration",
        "设置读取失败，请重新选择": "Settings could not be read. Select them again.",
        "音频资源尚未完整释放": "Audio resources have not been fully released",
        "仍然退出会结束 Auxmo 的音频处理，应用原声可能恢复，残留多输出设备可能需要手动移除。": "Quitting will end Auxmo's audio processing. Original app audio may resume, and remaining multi-output devices may need manual removal.",
        "仍然退出": "Quit Anyway",
        "系统未在期限内完成音频资源释放。": "macOS did not finish releasing audio resources before the deadline.",
        "设备未在期限内确认静音变更，请重新选择输出": "The device did not confirm mute before the deadline. Select an output again.",
        "退出": "Quit",
        "版本 %@": "Version %@",
        "重试释放": "Retry Release",
        "暂无正在播放的应用": "No Apps Playing Audio",
        "播放音频后，可在这里单独调节音量": "Play audio to adjust each app’s volume here.",
        "音频状态不可用": "Audio status unavailable",
        "等待音频流": "Waiting for audio stream",
        "音频流活跃": "Audio stream active",
        "等待应用创建音频流": "Waiting for the app to create an audio stream",
        "音频流空闲": "Audio stream idle",
        "应用捕获与输出的音频格式尚未一致，请重新应用":
            "The app capture and output formats have not matched yet. Reapply the configuration.",
        "应用播放增益，不影响麦克风输入": "App playback gain does not affect microphone input",
        "音效": "Effects",
        "音效：关闭": "Effects: Off",
        "音效：%@": "Effects: %@",
        "启用应用音效": "Enable App Effects",
        "均衡器": "Equalizer",
        "空间": "Spatial",
        "空间效果": "Spatial Effects",
        "动态": "Dynamics",
        "声道": "Channels",
        "音量均衡": "Volume Leveling",
        "夜间": "Night",
        "减少声音忽大忽小。": "Reduce sudden changes in volume.",
        "调整左右声音的大小。": "Adjust the volume of each side.",
        "左右播放相同声音。": "Play the same sound on both sides.",
        "对调左右声音。": "Switch the left and right channels.",
        "轻度": "Light",
        "强": "Strong",
        "单声道": "Mono",
        "左右平衡": "Balance",
        "交换左右声道": "Swap Left and Right",
        "将左右声道混合，适合只戴一只耳机时使用。":
            "Mix left and right channels for listening with one earbud.",
        "左": "Left",
        "右": "Right",
        "居中": "Center",
        "缩小响声与轻声的差距，不保证所有内容响度一致。":
            "Reduce the difference between loud and quiet sounds; levels may still vary between sources.",
        "房间": "Room",
        "大厅": "Hall",
        "人声空间": "Vocal Space",
        "混响强度": "Reverb Amount",
        "仅影响 %@，不会改变其他 App": "Affects %@ only and leaves other apps unchanged",
        "为每个应用提供均衡器、空间效果和预设。":
            "Add an EQ, spatial effects, and presets for each app.",
        "关闭后不会改变该应用的声音。": "When off, this app’s sound is unchanged.",
        "预设": "Preset",
        "预设 1": "Preset 1",
        "内置": "Built-in",
        "我的预设": "My Presets",
        "平坦": "Flat",
        "语音增强": "Voice Boost",
        "播客": "Podcast",
        "音乐": "Music",
        "电影": "Movie",
        "低音增强": "Bass Boost",
        "自定义": "Custom",
        "已修改": "Modified",
        "另存为预设": "Save as Preset",
        "重置": "Reset",
        "重命名…": "Rename…",
        "重命名预设": "Rename Preset",
        "复制": "Duplicate",
        "删除…": "Delete…",
        "删除预设？": "Delete Preset?",
        "保存": "Save",
        "重命名": "Rename",
        "删除": "Delete",
        "预设名称": "Preset Name",
        "预设 %d": "Preset %d",
        "预设 %d 副本": "Preset %d Copy",
        "%@ 副本": "%@ Copy",
        "%@ 副本 %d": "%@ Copy %d",
        "保存当前配置": "Save current configuration",
        "已使用该预设的 App 会保留当前声音，并显示为“自定义”。":
            "Apps using this preset keep their current sound and become “Custom”.",
        "设置中的“启用应用音效”当前已关闭，此配置会在重新开启后生效。":
            "Enable App Effects is off in Settings. These settings apply when it is turned back on.",
        "对比原声": "Compare Original",
        "临时对比未处理的声音，不修改已保存设置":
            "Compare the unprocessed sound without changing saved settings",
        "频响曲线预览；使用下方推子调整":
            "Response curve preview; use the faders below to adjust",
        "%@ 增益": "%@ Gain",
        "应用音效必须包含十个有效增益":
            "App effects must contain ten valid gains",
        "应用音效增益必须在 -12～12 dB 之间":
            "App effect gains must be between -12 and 12 dB",
        "空间效果强度必须在 0～100% 之间":
            "Spatial effect intensity must be between 0 and 100%",
        "该应用没有稳定身份，不能保存应用音效":
            "This app has no stable identity, so its effects cannot be saved",
        "预设名称不能为空，且不能超过 40 个字符":
            "Preset names must be 1–40 characters long",
        "已存在同名预设": "A preset with this name already exists",
        "自动防削波": "Automatic clipping protection",
        "已启用应用音效": "App effects applied",
        "应用音效配置无法读取，请检查本地设置":
            "App effect settings could not be read. Check local settings.",
        "应用音效配置无法保存，请检查本地设置":
            "App effect settings could not be saved. Check local settings.",
        "重试电平": "Retry Level",
        "重新应用音量": "Reapply Volume",
        "应用配置": "Apply Configuration",
        "停止管理": "Stop Managing",
        "未应用；请从选项中重新应用": "Not applied; reapply from the menu",
        "已应用音量配置": "Volume configuration applied",
        "正在读取实时电平": "Reading live levels",
        "等待音频流注册后应用": "Apply after the audio stream is registered",
        "尚未读取": "Not read yet",
        "低于负 60 dBFS": "Below -60 dBFS",
        "多设备输出": "Multi-Device Output",
        "多设备输出 · %d 台": "Multi-Device Output · %d Devices",
        "多设备输出待释放": "Multi-Device Output Pending Release",
        "清理残留设备": "Clean Up Leftover Device",
        "关闭多设备输出提示": "Dismiss Multi-Device Output Message",
        "不支持系统音量": "System volume unavailable",
        "不支持输入音量": "Input volume unavailable",
        "不支持统一音量": "Shared volume unavailable",
        "尚未读取设备控制状态": "Device controls not read",
        "%@ 尚未读取输入控制状态": "%@: input controls not read",
        "读取失败": "Read failed",
        "暂无可用麦克风": "No microphone available",
        "设备未公开静音状态": "Device does not expose mute state",
        "设备未公开可写的硬件静音控制": "Device does not expose writable hardware mute",
        "已静音": "Muted",
        "未静音": "Not muted",
        "切换设备静音": "Toggle device mute",
        "输入音量；不采集音频": "Input volume; does not capture audio",
        "设备音量；不会切换默认输出": "Device volume; does not change the default output",
        "设备音量只读": "Device volume is read-only",
        "设为默认输出：%@": "Set as default output: %@",
        "设为默认输入：%@": "Set as default input: %@",
        "切换为默认输出 · %@": "Switch to default output · %@",
        "切换为默认输入 · %@": "Switch to default input · %@",
        "结束多设备输出，仅使用“%@”播放": "End multi-device output and play only on “%@”",
        "%@ 静音": "Mute %@",
        "取消静音 %@": "Unmute %@",
        "静音 %@": "Mute %@",
        "取消静音": "Unmute",
        "静音": "Mute",
        "%@ 的实时音频电平": "Live audio level for %@",
        "%@ 的独立增益": "Independent gain for %@",
        "%@；右键打开应用操作": "%@; right-click for app actions",
        "%@ 的设备音量": "%@ device volume",
        "%@ 尚未读取设备控制状态": "%@: device controls not read",
        "%@ 的输入音量": "%@ input volume",
        "电平尚未读取": "Level not read",
        "实时音频电平": "Live audio level",
        "当前默认输出": "Current default output",
        "当前默认输入": "Current default input",
        "切换为默认输出": "Switch to default output",
        "切换为默认输入": "Switch to default input",
        "连接耳机": "Connect Headphones",
        "连接支持的蓝牙耳机后会自动启用控制":
            "Control connects automatically for supported Bluetooth headphones",
        "重试": "Retry",
        "重新扫描": "Scan Again",
        "取消重连": "Cancel Reconnection",
        "刷新": "Refresh",
        "断开": "Disconnect",
        "取消": "Cancel",
        "耳机噪声控制": "Headphone Noise Control",
        "该耳机尚未确认噪声控制能力": "Noise control capability has not been confirmed",
        "正在断开耳机": "Disconnecting headphones",
        "正在充电": "Charging",
        "耳机电量 %d%%": "Headphone battery %d%%",
        "无法确定当前耳机，请重新扫描": "Unable to identify the current headphones. Scan again.",
        "耳机控制尚未连接": "Headphone controls are not connected",
        "等待蓝牙授权与就绪": "Waiting for Bluetooth permission and readiness",
        "正在寻找耳机…": "Looking for headphones…",
        "请选择你的耳机": "Choose your headphones",
        "正在连接控制通道…": "Connecting the control channel…",
        "正在验证耳机服务…": "Verifying headphone services…",
        "正在验证耳机": "Verifying headphones",
        "已连接": "Connected",
        "正在断开控制通道…": "Disconnecting the control channel…",
        "控制连接失败": "Control connection failed",
        "关闭": "Off",
        "开启": "On",
        "降噪": "Noise Cancellation",
        "透传": "Transparency",
        "抗风噪": "Wind Reduction",
        "自适应": "Adaptive",
        "耳机电量：%@": "Headphone battery: %@",
        "耳机电量：身份尚未确认": "Headphone battery: identity not verified",
        "耳机电量：未读取": "Headphone battery: not read",
        "耳机电量：读数无效": "Headphone battery: invalid reading",
        "耳机电量：%d%%": "Headphone battery: %d%%",
        "从多设备输出移除：%@": "Remove from multi-device output: %@",
        "加入多设备输出：%@": "Add to multi-device output: %@",
        "从多设备输出移除“%@”": "Remove “%@” from multi-device output",
        "将“%@”加入多设备输出": "Add “%@” to multi-device output",
        "切换“%@”静音": "Toggle mute for “%@”",
        "%@ 的多设备输出音量": "Multi-device output volume for %@",
        "调节“%@”独立音量；不会切换默认输出":
            "Adjust independent “%@” volume; does not change the default output",
        "收起多设备输出": "Collapse multi-device output",
        "展开并更改多设备输出": "Expand and change multi-device output",
        "取消多设备输出静音": "Unmute multi-device output",
        "静音多设备输出": "Mute multi-device output",
        "多设备输出总音量": "Multi-device output master volume",
        "选择一台扬声器继续播放": "Choose a speaker to continue playback",
        "上次的多设备输出还在，清理后可重新设置":
            "Previous multi-device output is still present; clean it up before setting up again",
        "选择上面的扬声器后，可调节 APP 音量与电平": "Select a speaker above to adjust app volume and levels",
        "当前系统输出不支持 APP 独立音量与电平": "The current system output does not support per-app volume and levels",
        "全部输出": "All Outputs",
        "全部输出（默认）": "All Outputs (Default)",
        "全部输出：自动包含新增设备": "All Outputs: new group devices are included automatically",
        "自定义输出：%@": "Custom output: %@",
        "至少选择一台输出设备": "Select at least one output device",
        "应用路由仅在多设备输出模式下可用":
            "App routing is available only in multi-device output mode",
        "应用路由目标必须来自当前多设备输出组":
            "App routing targets must belong to the current multi-device group",
        "该应用没有稳定身份，不能设置持久应用路由":
            "This app has no stable identity, so its route cannot be saved",
        "已应用自定义路由": "Custom route applied",
        "应用路由配置无法读取，请检查本地设置":
            "Could not read the app routing configuration. Check the local settings.",
        "应用路由配置无法保存，请检查本地设置":
            "Could not save the app routing configuration. Check the local settings.",
        "当前没有可用的默认输出设备": "No default output device is currently available",
        "所选输出设备已断开": "The selected output device disconnected",
        "系统未确认输出切换，请刷新后检查":
            "macOS did not confirm the output switch. Refresh and check again.",
        "无法读回当前路由快照": "Could not read back the current routing snapshot",
        "旧 APP 音频资源尚未释放，未切换输出":
            "The previous app audio resources have not been released, so the output was not switched.",
        "旧 APP 音频资源尚未暂停，未切换输出":
            "The previous app audio resources have not been paused, so the output was not switched.",
        "当前没有可用系统输出，请恢复后点重新应用。":
            "No system output is currently available. Restore it and reapply."
    ]
}

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppLanguage.chinese
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}
