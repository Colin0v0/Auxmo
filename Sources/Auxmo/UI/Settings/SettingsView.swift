import AppKit
import SwiftUI
import AuxmoCore
import ServiceManagement

/// 登录项状态来自系统服务，错误只在当前设置窗口展示。
@MainActor
private final class LoginItemState: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?
}

/// 独立窗口只承载产品设置，不再复制主面板的设备控制。
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    /// 嵌入主窗口时复用设置内容，不再生成第二个标题和固定宽度窗口。
    var embedded = false
    @ObservedObject private var updates = AuxmoUpdateChecker.shared
    @ObservedObject private var batteryReminder = LowBatteryReminder.shared
    @StateObject private var loginItem = LoginItemState()
    @StateObject private var updateCheckHover = PanelRowHoverState()
    @StateObject private var projectLinkHover = PanelRowHoverState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !embedded { header }
            if !settings.readErrors.isEmpty {
                Text(settings.localized("设置读取失败，请重新选择"))
                    .font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary)
                    .help(settings.readErrors.values.sorted().joined(separator: "\n"))
            }
            generalCard
            featuresCard
            diagnosticsCard
            // 检查更新始终位于设置内容最后，独立窗口和完整窗口保持一致。
            footer
        }
        .padding(embedded ? 0 : SettingsMetrics.horizontalInset)
        .frame(maxWidth: embedded ? .infinity : SettingsMetrics.width,
               alignment: .topLeading)
        .background(PanelStyle.canvas)
        .foregroundStyle(PanelStyle.ink)
        .preferredColorScheme(settings.appearance?.colorScheme)
        // 设置页内的分段控件也读取环境语言；在这里统一注入，避免标题已翻译而“关闭 / 开启”仍显示中文。
        .environment(\.appLanguage, settings.resolvedLanguage)
        .onChange(of: scenePhase) { _, phase in
            // 从系统设置返回时重新读取真实登录项状态，不用本地偏好冒充注册结果。
            if phase == .active {
                loginItem.enabled = SMAppService.mainApp.status == .enabled
            }
        }
        .alert(settings.localized("通知权限未开启"), isPresented: Binding(
            get: { batteryReminder.permissionMessage != nil },
            set: { if !$0 { batteryReminder.permissionMessage = nil } }
        )) {
            Button(settings.localized("打开系统设置")) { batteryReminder.openNotificationSettings() }
            Button(settings.localized("取消"), role: .cancel) { }
        } message: {
            Text(batteryReminder.permissionMessage ?? "")
        }
        .alert(settings.localized("无法更改开机启动"), isPresented: Binding(
            get: { loginItem.error != nil },
            set: { if !$0 { loginItem.error = nil } }
        )) {
            Button(settings.localized("好"), role: .cancel) { loginItem.error = nil }
        } message: {
            Text(loginItem.error ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(PanelStyle.accent)
                .frame(width: 34, height: 34)
                .background(PanelStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            Text(settings.localized("Auxmo 设置"))
                .font(.system(size: 16, weight: .semibold))
            Spacer()
        }
    }

    private var generalCard: some View {
        SettingsCard(title: settings.localized("通用")) {
            SettingsRow(title: settings.localized("界面语言")) {
                PanelSegmentedControl(items: AppLanguage.allCases.map(Optional.some), selection: $settings.language,
                                      title: languageTitle)
                .frame(width: SettingsMetrics.controlWidth)
            }
            PanelDivider()
            SettingsRow(title: settings.localized("外观")) {
                PanelSegmentedControl(items: AppAppearance.allCases.map(Optional.some), selection: $settings.appearance,
                                      title: appearanceTitle)
                .frame(width: SettingsMetrics.controlWidth)
            }
            PanelDivider()
            SettingsToggleRow(
                title: settings.localized("开机启动"),
                detail: settings.localized("登录 Mac 后自动运行 Auxmo。"),
                isOn: Binding(get: { loginItem.enabled }, set: setLaunchAtLogin)
            )
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        // 仅在用户操作时注册；首次运行不主动启用，也不创建额外启动脚本。
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItem.enabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            loginItem.enabled = SMAppService.mainApp.status == .enabled
            loginItem.error = error.localizedDescription
        }
    }

    private var featuresCard: some View {
        SettingsCard(title: settings.localized("功能")) {
            SettingsToggleRow(
                title: settings.localized("显示耳机控制页"),
                detail: settings.localized("关闭后，耳机控制从主面板隐藏。"),
                isOn: $settings.showHeadphoneControls
            )
            PanelDivider()
            SettingsToggleRow(
                title: settings.localized("显示多设备输出"),
                detail: settings.localized("关闭后，多设备输出功能从输出面板隐藏。"),
                isOn: simultaneousOutputBinding
            )
            PanelDivider()
            SettingsToggleRow(
                title: settings.localized("启用应用音效"),
                detail: settings.localized("为每个应用提供均衡器、空间效果和预设。"),
                isOn: applicationEffectsBinding
            )
            PanelDivider()
            SettingsToggleRow(
                title: settings.localized("菜单栏设备图标"),
                detail: settings.localized("开启后，图标会显示当前使用的电脑、耳机或显示器。"),
                isOn: $settings.showMenuBarDeviceIcon
            )
            PanelDivider()
            MenuBarBatterySettingsRow(settings: settings, group: model.headphones)
            PanelDivider()
            SettingsToggleRow(
                title: settings.localized("低电量提醒"),
                detail: settings.localized("耳机电量降至 20% 时发送通知。"),
                isOn: Binding(get: { settings.lowBatteryReminderEnabled }, set: { value in
                    if let value { batteryReminder.setEnabled(value) }
                })
            )
            .disabled(batteryReminder.isRequesting)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 检查更新保持独立一行，右侧只显示一个文字入口。
            PanelDivider()
            HStack(spacing: 12) {
                // 沿用构建时注入的项目地址，点击版本文字打开 GitHub 仓库。
                Button("Auxmo \(AuxmoVersion.current)") {
                    if let url = AuxmoProjectLinks.repositoryURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.plain)
                .font(PanelStyle.bodyFont)
                .foregroundStyle(projectLinkHover.active ? PanelStyle.ink : PanelStyle.secondary)
                .onHover { projectLinkHover.active = $0 }
                .help("GitHub")
                Spacer(minLength: 12)
                Button {
                    updates.check(force: true)
                } label: {
                    Text(updateCheckTitle)
                }
                .buttonStyle(.plain)
                .font(PanelStyle.bodyFont)
                .foregroundStyle(updateCheckHover.active && !updates.isChecking
                                 ? PanelStyle.ink : PanelStyle.secondary)
                .onHover { updateCheckHover.active = $0 }
                .disabled(updates.isChecking)
                .help(updates.lastError ?? settings.localized("检查更新"))
                .accessibilityIdentifier("settings.checkForUpdates")
            }
            .frame(minHeight: SettingsMetrics.rowHeight)
        }
        .padding(.top, 8)
    }

    /// 同一个文字入口显示检查状态；结果出现后仍可点击重新检查。
    private var updateCheckTitle: String {
        if updates.isChecking { return settings.localized("正在检查更新…") }
        if let update = updates.availableUpdate {
            return settings.localizedFormat("发现新版本 %@", update.version)
        }
        if updates.lastError != nil { return settings.localized("检查失败，重试") }
        if updates.didCheckWithoutUpdate { return settings.localized("未发现新版本") }
        return settings.localized("检查更新")
    }

    private var diagnosticsCard: some View {
        SettingsCard(title: settings.localized("诊断")) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.localized("错误日志"))
                        .font(PanelStyle.bodyFont)
                    Text(settings.localized("导出音频状态与错误日志。"))
                        .font(PanelStyle.captionFont)
                        .foregroundStyle(PanelStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(settings.localized("导出诊断报告…")) {
                    exportDiagnostics()
                }
                .buttonStyle(PanelButtonStyle(prominent: true))
            }
            .padding(.vertical, 8)
            .frame(minHeight: 52)
        }
    }

    private func exportDiagnostics() {
        let report = model.makeDiagnosticReport()
        do {
            guard let url = try AuxmoDiagnosticExporter.save(report) else { return }
            // 只记录导出路径的本地文件名，不把用户目录写进下一次诊断报告。
            model.diagnosticEventLog.record(category: "diagnostics",
                                            message: "saved \(url.lastPathComponent)")
        } catch {
            model.diagnosticEventLog.record(category: "diagnostics",
                                            message: "export failed: \(error.localizedDescription)")
            presentDiagnosticError(settings.localized("无法导出诊断报告"), error.localizedDescription)
        }
    }

    private func presentDiagnosticError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: settings.localized("好"))
        alert.runModal()
    }

    private var simultaneousOutputBinding: Binding<Bool?> {
        Binding(
            get: { settings.showSimultaneousOutput },
            set: { value in
                guard let enabled = value else { return }
                if enabled {
                    settings.showSimultaneousOutput = true
                    return
                }
                // 先完成真实资源释放；只有没有残留组合设备时才隐藏功能入口。
                model.stopSimultaneousOutput()
                if !model.outputRouting.phase.isBusy, model.outputRouting.phase != .failed,
                   model.outputRouting.pendingCleanup.isEmpty {
                    settings.showSimultaneousOutput = false
                }
            }
        )
    }

    private var applicationEffectsBinding: Binding<Bool?> {
        Binding(
            get: { settings.appAudioEffectsEnabled },
            set: { value in
                guard let enabled = value else { return }
                // 设置持久化与运行时旁路同时更新，关闭后不会留下不可见的后台音效处理。
                settings.appAudioEffectsEnabled = enabled
                model.setApplicationEffectsEnabled(enabled)
            }
        )
    }

    private func languageTitle(_ value: AppLanguage?) -> String {
        guard let language = value else { return settings.localized("设置读取失败，请重新选择") }
        switch language {
        case .system: return settings.localized("跟随系统")
        case .chinese: return settings.localized("简体中文")
        case .english: return "English"
        }
    }

    private func appearanceTitle(_ value: AppAppearance?) -> String {
        guard let appearance = value else { return settings.localized("设置读取失败，请重新选择") }
        switch appearance {
        case .system: return settings.localized("跟随系统")
        case .light: return settings.localized("浅色")
        case .dark: return settings.localized("深色")
        }
    }
}

enum SettingsMetrics {
    // 分组标题、设置项与分隔线共用窗口留白，内层不再叠加缩进。
    static let horizontalInset: CGFloat = 18
    static let width: CGFloat = 500
    static let controlWidth: CGFloat = 238
    static let booleanControlWidth: CGFloat = 116
    static let rowHeight: CGFloat = 40

    /// 设置页固定宽度，高度完全来自当前内容的首选尺寸。
    static func contentSize(preferred: CGSize) -> CGSize {
        CGSize(width: width, height: ceil(preferred.height))
    }

    /// 内容增减时保持窗口左上角，按标题栏以外的真实内容高度调整外框。
    static func resizedWindowFrame(for window: NSWindow, contentSize: CGSize) -> CGRect {
        let contentRect = CGRect(origin: .zero, size: contentSize)
        var frame = window.frameRect(forContentRect: contentRect)
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        return frame
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PanelStyle.secondary)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                content()
            }
            // 内容与分组标题直接对齐，不再叠加原卡片的水平留白。
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    init(title: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.control = control
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(PanelStyle.bodyFont)
            Spacer(minLength: 12)
            control()
        }
        // 标题和说明与分组标题使用同一左边缘。
        .frame(height: SettingsMetrics.rowHeight)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool?

    init(title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = Binding(get: { isOn.wrappedValue }, set: { if let value = $0 { isOn.wrappedValue = value } })
    }

    init(title: String, detail: String, isOn: Binding<Bool?>) {
        self.title = title; self.detail = detail; _isOn = isOn
    }

    @Environment(\.appLanguage) private var language

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(PanelStyle.bodyFont)
                Text(detail)
                    .font(PanelStyle.captionFont)
                    .foregroundStyle(PanelStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            // 不可读时两项都不选中，不能把未知开关绘制成用户已选择“关闭”。
            PanelSegmentedControl(items: [Optional(false), Optional(true)], selection: $isOn) {
                L10n.text($0 == true ? "开启" : "关闭", language: language)
            }
                .frame(width: SettingsMetrics.booleanControlWidth)
                .accessibilityLabel(title)
        }
        // 标题和说明与分组标题使用同一左边缘。
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }
}

/// 电量来源是单选而不是开关；固定目标断开时仍保留选择，但菜单栏不显示替代耳机。
struct MenuBarBatterySettingsRow: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var group: HeadphoneControllerGroup

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(settings.localized("菜单栏电量"))
                    .font(PanelStyle.bodyFont)
                Text(settings.localized("固定设备断开后隐藏。"))
                    .font(PanelStyle.captionFont)
                    .foregroundStyle(PanelStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            // 外壳继续使用设置页现有白底细边框；展开项交给原生 NSMenu，避免自制菜单的视觉与键盘行为偏差。
            BatterySourceMenu(
                title: title(for: settings.menuBarBatterySource),
                selected: settings.menuBarBatterySource,
                items: sourceMenuItems,
                onSelect: { settings.menuBarBatterySource = $0 }
            )
            // 标题有多长就展示多长，不再用固定 150pt 截断成省略号。
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(settings.localized("菜单栏电量"))
        }
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }

    private var sourceMenuItems: [BatterySourceMenu.Item] {
        var items = [
            BatterySourceMenu.Item(title: settings.localized("不显示"), source: .off),
            BatterySourceMenu.Item(title: settings.localized("跟随当前输出"), source: .currentOutput)
        ]
        for (index, entry) in group.entries.enumerated() {
            items.append(BatterySourceMenu.Item(
                title: settings.localizedFormat("固定：%@", entry.output.name),
                source: .pinned(deviceUID: entry.id),
                separatorBefore: index == 0
            ))
        }
        if let disconnectedPinnedSource {
            items.append(BatterySourceMenu.Item(
                title: title(for: disconnectedPinnedSource),
                source: disconnectedPinnedSource,
                enabled: false
            ))
        }
        return items
    }

    private func title(for value: MenuBarBatterySource?) -> String {
        guard let source = value else { return settings.localized("设置读取失败，请重新选择") }
        switch source {
        case .off:
            return settings.localized("不显示")
        case .currentOutput:
            return settings.localized("跟随当前输出")
        case .pinned(let deviceUID):
            guard let entry = group.entries.first(where: { $0.id == deviceUID }) else {
                return settings.localized("固定设备（未连接）")
            }
            return settings.localizedFormat("固定：%@", entry.output.name)
        }
    }

    private var disconnectedPinnedSource: MenuBarBatterySource? {
        guard case .pinned(let deviceUID) = settings.menuBarBatterySource,
              !group.entries.contains(where: { $0.id == deviceUID }) else { return nil }
        return settings.menuBarBatterySource
    }
}
