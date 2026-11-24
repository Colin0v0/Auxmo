import SwiftUI
import AuxmoCore

/// 完整窗口的导航页；设置和控制页共享同一个主窗口，不再分裂成多个窗口。
enum DashboardPage: Hashable {
    case output, microphone, headphones, statistics, settings

    var title: String {
        switch self {
        case .output: return "输出"
        case .microphone: return "麦克风"
        case .headphones: return "耳机控制"
        case .statistics: return "统计"
        case .settings: return "设置"
        }
    }

    var displaysApplications: Bool { self == .output || self == .microphone }
}

/// 独立主窗口的完整页面。菜单栏只负责唤起窗口，详情内容不再塞进窄小浮层。
@MainActor
final class DashboardSelection: ObservableObject {
    @Published var page: DashboardPage = .statistics
    @Published var sidebarVisible = true
}

/// 侧边栏悬停不改变导航选中状态。
@MainActor
private final class DashboardHover: ObservableObject {
    @Published var page: DashboardPage?
}

struct MainDashboardView: View {
    @ObservedObject var model: AppModel
    let openApplicationAudioEffects: (String, String, URL?) -> Void
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var selection: DashboardSelection
    @ObservedObject private var updates = AuxmoUpdateChecker.shared
    @StateObject private var sidebarHover = DashboardHover()
    @StateObject private var sidebarToggleHover = PanelRowHoverState()
    @StateObject private var statisticsPresentation = ListeningStatisticsPresentation()
    @StateObject private var statisticsBreadcrumbHover = PanelRowHoverState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            // 内容始终保持固定宽度，只动画外层裁剪宽度，标题和按钮一起移动。
            sidebar
                .frame(width: selection.sidebarVisible ? 195 : 0, alignment: .trailing)
                .clipped()
                // 细线和阴影绑定同一个动画边缘，收起时随着宽度移动并淡出。
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(PanelStyle.ink.opacity(0.10))
                        .frame(width: 0.5)
                        .overlay(alignment: .trailing) {
                            LinearGradient(colors: [.black.opacity(0.045), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 7)
                                .offset(x: 7)
                        }
                        .opacity(selection.sidebarVisible ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .allowsHitTesting(selection.sidebarVisible)
                .accessibilityHidden(!selection.sidebarVisible)
                .zIndex(1)
            // 展开动画期间正文不能绘制到侧边栏区域，避免文字叠在导航文字上。
            content.clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 收纳按钮属于窗口而非侧边栏或正文，始终使用同一位置和同一个按钮实例。
        .overlay(alignment: .topLeading) {
            sidebarToggle
                .padding(.leading, 80)
                .padding(.top, 12)
        }
        // 整体连同叠加按钮一起延伸到透明标题栏，按钮才能与原生窗口控制居中对齐。
        .ignoresSafeArea(.container, edges: .top)
        .background(PanelStyle.canvas)
        .foregroundStyle(PanelStyle.ink)
        .preferredColorScheme(settings.appearance?.colorScheme)
        .environment(\.appLanguage, settings.resolvedLanguage)
        .onAppear {
            model.setMeteringVisible(true, for: .controlWindow)
            model.setApplicationMetersSelected(selection.page.displaysApplications, for: .controlWindow)
            // 完整窗口与轻量面板一样，只在麦克风页可见时读取系统输入设备。
            model.setInputControlsVisible(selection.page == .microphone, for: .controlWindow)
            model.refresh()
        }
        .onDisappear {
            model.setInputControlsVisible(false, for: .controlWindow)
            model.setMeteringVisible(false, for: .controlWindow)
        }
        .onChange(of: selection.page) { _, value in
            model.setApplicationMetersSelected(value.displaysApplications, for: .controlWindow)
            model.setInputControlsVisible(value == .microphone, for: .controlWindow)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部占位与正文导航等高，窗口层负责绘制收纳按钮。
            Color.clear.frame(height: 52).allowsHitTesting(false)

            sidebarGroupTitle("使用")
            sidebarButton(.output)
            sidebarButton(.microphone)
            sidebarButton(.headphones)

            sidebarGroupTitle("观测")
            sidebarButton(.statistics)

            Spacer(minLength: 20)
            // 设置与上方导航复用同一个按钮，字号、图标、间距和选中样式保持一致。
            sidebarButton(.settings)
                .padding(.bottom, 12)
        }
         .frame(width: 195)
        .background(PanelStyle.surface.opacity(0.65))
        // 半透明色下铺不透明画布，动画时不会透出正在移动的正文。
        .background(PanelStyle.canvas)
    }

    private func sidebarGroupTitle(_ title: String) -> some View {
        Text(settings.localized(title))
             .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PanelStyle.secondary)
             .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 5)
    }

    private func sidebarButton(_ item: DashboardPage) -> some View {
        Button { selection.page = item } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: item)).frame(width: 16, alignment: .leading)
                Text(settings.localized(item.title))
                Spacer(minLength: 0)
            }
             .font(PanelStyle.bodyFont)
            // 悬停只加深文字和图标，白色底板仍只表示当前选中页。
            .foregroundStyle(selection.page == item || sidebarHover.page == item ? PanelStyle.ink : PanelStyle.secondary)
            // 外层 10pt + 行内 8pt，与分组标题的 18pt 左边距一致。
            .padding(.horizontal, 8)
             .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(selection.page == item ? PanelStyle.tabSelection : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            // 整行都是按钮命中区，不只让文字和图标响应点击。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { sidebarHover.page = item }
            else if sidebarHover.page == item { sidebarHover.page = nil }
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .zIndex(1)
    }

    private func icon(for item: DashboardPage) -> String {
        switch item {
        case .output: return "speaker.wave.2"
        case .microphone: return "mic"
        case .headphones: return "headphones"
        case .statistics: return "chart.bar.xaxis"
        case .settings: return "gearshape"
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            navigationBar

            if selection.page == .statistics {
                // 详情跳转后由统计页滚动到顶部；日期仍和内容一起滚动。
                ListeningStatisticsView(statistics: model.listeningStatistics, presentation: statisticsPresentation,
                                        showsScrollView: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    pageContent
                        .environment(\.dashboardLayout, true)
                        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DashboardScrollbars())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarToggle: some View {
        Button {
            // 尊重系统的减少动态效果设置；其他情况下平滑移动侧边栏和正文。
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                selection.sidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13))
                // 鼠标悬停时与侧边栏导航项一样加深，不增加背景。
                .foregroundStyle(sidebarToggleHover.active ? PanelStyle.ink : PanelStyle.secondary)
                .frame(width: 22, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { sidebarToggleHover.active = $0 }
        .help(settings.localized(selection.sidebarVisible ? "收起侧边栏" : "展开侧边栏"))
        .accessibilityLabel(settings.localized(selection.sidebarVisible ? "收起侧边栏" : "展开侧边栏"))
    }

    /// 导航与检查更新共享顶部一行，页面正文不再重复显示大标题。
    private var navigationBar: some View {
        HStack(spacing: 10) {
            if !selection.sidebarVisible {
                // 为原生窗口按钮和固定位置的侧边栏按钮留出空间。
                Color.clear.frame(width: 94, height: 1).allowsHitTesting(false)
            }
            Text(settings.localized(selection.page == .settings ? "设置" : selection.page == .statistics ? "观测" : "使用"))
                .foregroundStyle(PanelStyle.secondary)
            Text("/").foregroundStyle(PanelStyle.secondary.opacity(0.55))
            if selection.page == .statistics, let title = statisticsPresentation.detailTitle {
                Button(settings.localized("统计")) { statisticsPresentation.returnToOverview() }
                    .buttonStyle(.plain)
                    .foregroundStyle(statisticsBreadcrumbHover.active ? PanelStyle.ink : PanelStyle.secondary)
                    .onHover { statisticsBreadcrumbHover.active = $0 }
                Text("/").foregroundStyle(PanelStyle.secondary.opacity(0.55))
                Text(title).fontWeight(.semibold).lineLimit(1)
            } else {
                Text(settings.localized(selection.page == .settings ? "常规" : selection.page.title))
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            // 有新版本才显示紫色更新入口；普通检查放在设置页底部。
            if updates.availableUpdate != nil {
                AuxmoUpdateCapsule(updates: updates, settings: settings)
            }
        }
        .font(PanelStyle.bodyFont)
        // 收起侧边栏只调整左侧窗口按钮的避让，右侧更新入口始终距窗口边缘 24pt。
        .padding(.leading, selection.sidebarVisible ? 24 : 10)
        .padding(.trailing, 24)
        .frame(height: 52)
    }

    @ViewBuilder private var pageContent: some View {
        switch selection.page {
        case .statistics:
            ListeningStatisticsView(statistics: model.listeningStatistics)
        case .headphones:
            HeadphoneControlsSection(group: model.headphones)
        case .output:
            outputContent
        case .microphone:
            microphoneContent
        case .settings:
            SettingsView(model: model, settings: settings, embedded: true)
        }
    }

    private var outputContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let audio = model.audio {
                OutputRoutingSection(audio: audio, routing: model.outputRouting,
                                     select: model.selectOutputDevice,
                                     setVolume: { model.setOutputVolume($0, on: $1) },
                                     setMuted: { model.setOutputMuted($0, on: $1) },
                                     stop: model.stopSimultaneousOutput,
                                     dismissError: model.dismissSimultaneousOutputError,
                                     setSimultaneousVolume: model.setSimultaneousOutputVolume,
                                     setSimultaneousMuted: model.setSimultaneousOutputMuted,
                                     toggleMember: model.toggleSimultaneousMember,
                                     showSimultaneousOutput: settings.showSimultaneousOutput == true)
            }
            PanelDivider()
            ApplicationVolumeSection(model: model, metersVisible: true,
                                     routingEnabled: model.applicationAudioRoutingEnabled,
                                     effectsEnabled: model.applicationEffectsEnabled,
                                     openApplicationAudioEffects: openApplicationAudioEffects)
        }
    }

    private var microphoneContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 显示真实读取和操作错误，不能把输入枚举失败表现成空白区域。
            if let error = model.inputError {
                PanelError(text: settings.localized(error))
            }
            if let error = model.inputOperationError {
                PanelError(text: settings.localized(error))
            }
            if let input = model.inputAudio {
                InputDevicesSection(audio: input, select: model.selectInput,
                                    setVolume: { model.setInputVolume($0, on: $1) },
                                    setMuted: { model.setInputMuted($0, on: $1) })
            } else if model.inputError == nil {
                ProgressView("正在读取麦克风…")
                    .controlSize(.small)
                    .font(PanelStyle.captionFont)
                    .foregroundStyle(PanelStyle.secondary)
            }
            PanelDivider()
            ApplicationVolumeSection(model: model, metersVisible: true,
                                     routingEnabled: false,
                                     effectsEnabled: false,
                                     openApplicationAudioEffects: openApplicationAudioEffects)
        }
    }
}
