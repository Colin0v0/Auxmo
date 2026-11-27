import AppKit
import Combine
import SwiftUI
import AuxmoCore


/// 主窗口的最小尺寸由窗口层强制执行，避免 SwiftUI 宿主或系统恢复旧 frame 时绕过 minSize。
final class AuxmoDashboardWindow: NSWindow {
    static let minimumContentSize = NSSize(width: 900, height: 700)
    /// 初次打开使用最小尺寸，用户仍可自行调整窗口大小。
    static let initialContentSize = minimumContentSize
    static let maximumContentWidth: CGFloat = 1080

    /// 使用系统红黄绿按钮，只调整它们在一体式导航栏中的位置。
    func layoutWindowControls() {
        guard !styleMask.contains(.fullScreen), let contentView else { return }
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = standardWindowButton(type), let parent = button.superview else { continue }
            let center = parent.convert(NSPoint(x: 17 + CGFloat(index) * 20,
                                                 y: contentView.isFlipped ? contentView.bounds.minY + 26 : contentView.bounds.maxY - 26), from: contentView)
            button.setFrameOrigin(NSPoint(x: center.x - button.frame.width / 2,
                                          y: center.y - button.frame.height / 2))
        }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        var constrained = super.constrainFrameRect(frameRect, to: screen)
        let minimumFrameSize = self.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)).size
        let oldSize = constrained.size
        constrained.size.width = max(constrained.size.width, minimumFrameSize.width)
        constrained.size.height = max(constrained.size.height, minimumFrameSize.height)
        // 保持窗口左上角不跳动：增大尺寸时只向右下方展开。
        constrained.origin.y -= constrained.size.height - oldSize.height
        return constrained
    }
}

/// SwiftUI 完成布局后对齐系统窗口按钮，缩放与侧边栏切换都使用同一处布局。
@MainActor
final class DashboardHostingController: NSHostingController<MainDashboardView> {
    override func viewDidLayout() {
        super.viewDidLayout()
        (view.window as? AuxmoDashboardWindow)?.layoutWindowControls()
    }
}

/// 设置内容高度变化时同步原生窗口，避免语言、错误提示或分组内容被固定高度裁切。
@MainActor
private final class SettingsHostingController: NSHostingController<SettingsView> {
    var contentSizeDidChange: ((CGSize) -> Void)?
    private var lastReportedSize = CGSize.zero

    override func viewDidLayout() {
        super.viewDidLayout()
        reportContentSize()
    }

    func reportContentSize() {
        let preferred = preferredContentSize
        guard preferred.width > 0, preferred.height > 0 else { return }
        let size = SettingsMetrics.contentSize(preferred: preferred)
        guard size != lastReportedSize else { return }
        lastReportedSize = size
        contentSizeDidChange?(size)
    }
}

/// 菜单栏浮层完全由自己持有：打开时确定一次锚点，之后只沿该锚点改变高度。
@MainActor
final class StatusPanelController: NSObject {
    private let popup: StatusPopupPanel
    private let statusItem: NSStatusItem
    private let model: AppModel
    private var mainWindow: NSWindow?
    private let dashboardSelection = DashboardSelection()
    private lazy var applicationAudioEffectWindowController = ApplicationAudioEffectWindowController(model: model)
    private var audioPermissionMonitor: AudioCapturePermissionMonitor?
    private let popupLayout = PanelPresentationLayout()
    private let popupSizeAnimator = PanelSizeAnimator()
    private var popupTopLeft = CGPoint.zero
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var statusBatteryCancellables: Set<AnyCancellable> = []
    private var presentationGeneration: UInt64 = 0
    private var popupPresented = false

    init(model: AppModel, requestAudioPermission: @escaping () async throws -> Bool,
         onAudioPermissionGranted: @escaping () -> Void,
         onAudioPermissionDenied: @escaping () -> Void) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let initialSize = PanelMetrics.size(contentHeight: 0)
        popup = StatusPopupPanel(contentRect: NSRect(origin: .zero, size: initialSize),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        popup.delegate = self
        popup.backgroundColor = .clear
        popup.isOpaque = false
        popup.hasShadow = true
        popup.isMovable = false
        popup.isMovableByWindowBackground = false
        popup.isReleasedWhenClosed = false
        popup.hidesOnDeactivate = false
        // 主面板位于普通窗口之上、系统菜单之下，允许右键菜单覆盖它而不互相抢层级。
        popup.level = .statusBar
        popup.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        popup.animationBehavior = .none
        popup.dismiss = { [weak self] in self?.hidePopup() }
        popupLayout.selectPage(AudioPanelPage.output)
        let layout = popupLayout
        let host = NSHostingController(rootView: StatusPopupSurface { [weak self] in
            AudioPanel(model: model, layout: layout, openSettings: { [weak self] in
                self?.showSettings()
            }, openMainWindow: { [weak self] in
                self?.showMainWindow()
            }, openApplicationAudioEffects: { [weak self] applicationID, appName, applicationURL in
                self?.showApplicationAudioEffects(applicationID: applicationID,
                                                  appName: appName,
                                                  applicationURL: applicationURL)
            }, panelSizeChanged: { [weak self] size in
                self?.updatePopupSize(size)
            }, surface: .popover)
        })
        host.sizingOptions = []
        host.view.setFrameSize(initialSize)
        popup.contentViewController = host
        popup.installNativeBackdrop()
        if let button = statusItem.button {
            button.image = AuxmoStatusIcon.make()
            button.image?.accessibilityDescription = "Auxmo 音频控制"
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            button.target = self
            button.action = #selector(handleStatusItemAction)
            button.sendAction(on: StatusItemInteraction.actionEvents)
            button.toolTip = "Auxmo · 左键打开/收起，右键更多操作"
        }
        updateStatusItemBattery()
        statusBatteryCancellables.insert(AppSettings.shared.$menuBarBatterySource
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusItemBattery() }
            })
        statusBatteryCancellables.insert(AppSettings.shared.$showMenuBarDeviceIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusItemBattery() }
            })
        statusBatteryCancellables.insert(AppSettings.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusItemBattery() }
            })
        statusBatteryCancellables.insert(model.headphones.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusItemBattery() }
            })
        // 当前输出和聚合成员变化都会改变“跟随当前输出”的唯一目标。
        statusBatteryCancellables.insert(model.$audio
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusItemBattery() }
            })
        statusBatteryCancellables.insert(model.$outputRouting
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusItemBattery() }
            })
        audioPermissionMonitor = AudioCapturePermissionMonitor(
            access: model.$audioCaptureAccess.eraseToAnyPublisher(),
            currentAccess: { model.audioCaptureAccess },
            requestDecision: { completion in
                Task { @MainActor in
                    do { completion(try await requestAudioPermission() ? .authorized : .denied) }
                    catch {
                        model.operationError = error.localizedDescription
                        completion(.unavailable)
                    }
                }
            },
            restartAfterGrant: onAudioPermissionGranted,
            quitWithoutPermission: { [weak self] in
                // 权限失效属于不可恢复的运行状态，先收起主面板再显示独立的权限提示框。
                self?.hidePopup()
                onAudioPermissionDenied()
            })
    }

    /// 齿轮和右键菜单都进入同一个真实设置窗口，不再复制主面板的设备控制内容。
    /// 菜单栏入口打开完整主窗口；统计、设备和应用控制都在同一页内浏览。
    func showMainWindowForDock() {
        showMainWindow()
    }

    private func showMainWindow() {
        hidePopup()
        // 主窗口打开时显示 Dock 图标；关闭窗口后回到纯菜单栏运行状态。
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            let host = DashboardHostingController(rootView: MainDashboardView(
                model: model,
                openApplicationAudioEffects: { [weak self] applicationID, appName, applicationURL in
                    self?.showApplicationAudioEffects(applicationID: applicationID, appName: appName, applicationURL: applicationURL)
                },
                selection: dashboardSelection))
            // 主窗口尺寸完全由 AppKit 管理；SwiftUI 不再用自然内容尺寸反向改写窗口。
            host.sizingOptions = []
            let window = AuxmoDashboardWindow(contentRect: NSRect(origin: .zero, size: AuxmoDashboardWindow.initialContentSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Auxmo"
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(AuxmoDashboardWindow.initialContentSize)
            window.contentMaxSize = NSSize(width: AuxmoDashboardWindow.maximumContentWidth,
                                           height: .greatestFiniteMagnitude)
            // 最小尺寸必须同时约束内容区和外框，避免不同缩放路径绕过 SwiftUI 的页面边界。
            window.contentMinSize = AuxmoDashboardWindow.minimumContentSize
            window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: AuxmoDashboardWindow.minimumContentSize)).size
            window.center()
            window.delegate = self
            mainWindow = window
        }
        // 已经创建过的窗口也重新施加约束，避免用户从旧版本继承过小的窗口尺寸。
        mainWindow?.contentMinSize = AuxmoDashboardWindow.minimumContentSize
        mainWindow?.minSize = mainWindow?.frameRect(forContentRect: NSRect(origin: .zero, size: AuxmoDashboardWindow.minimumContentSize)).size ?? .zero
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettings() {
        // 设置和主内容共享同一个窗口；轻量面板的齿轮直接定位到设置页。
        dashboardSelection.page = .settings
        showMainWindow()
    }

    /// 应用音效不再使用主面板 Popover；独立窗口由同一个控制器强持有，避免播放列表刷新时窗口被释放。
    private func showApplicationAudioEffects(applicationID: String, appName: String,
                                             applicationURL: URL?) {
        hidePopup()
        applicationAudioEffectWindowController.show(
            applicationID: applicationID,
            appName: appName,
            applicationURL: applicationURL
        )
    }

    private func updatePopupSize(_ size: CGSize) {
        guard size == popupLayout.size else { return }
        // 一次计算目标外框并固定打开时的顶边；高度直接落位，顶边不参与窗口动画。
        let target = StatusPopupMetrics.frame(topLeft: popupTopLeft, size: size)
        popupSizeAnimator.settleAfterLayout(window: popup, to: target)
    }

    private func showPopup() {
        // 菜单里的“打开”是幂等操作，不会因浮层已经显示而反向收起。
        guard !popupPresented else { return }
        guard let button = statusItem.button, let buttonWindow = button.window, let screen = buttonWindow.screen else {
            assertionFailure("状态栏按钮尚无可用的屏幕锚点")
            return
        }
        let statusFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        popupLayout.setAvailableHeight(StatusPopupMetrics.availableHeight(statusItem: statusFrame,
                                                                          screen: screen.visibleFrame))
        popup.contentView?.layoutSubtreeIfNeeded()
        popupLayout.beginPresentation()
        let frame = StatusPopupMetrics.openingFrame(statusItem: statusFrame, screen: screen.visibleFrame,
                                                   contentSize: popupLayout.size)
        popupTopLeft = CGPoint(x: frame.minX, y: frame.maxY)
        popupSizeAnimator.cancel()
        // 设置页切换主题时主面板通常已收起；重新展示前再写入一次原生底色。
        popup.installNativeBackdrop()
        popup.presentImmediately(frame: frame)
        popupPresented = true
        button.highlight(true)
        presentationGeneration &+= 1
        installDismissMonitors(generation: presentationGeneration)
        model.setMeteringVisible(true, for: .popover)
        // 面板重新出现时补一次完整状态；隐藏期间只监听路由，避免后台反复扫描进程。
        Task { @MainActor [weak self] in self?.model.refresh() }
    }

    private func hidePopup() {
        guard popupPresented else { return }
        popupPresented = false
        presentationGeneration &+= 1
        popupSizeAnimator.cancel()
        removeDismissMonitors()
        popup.orderOut(nil)
        statusItem.button?.highlight(false)
        model.setMeteringVisible(false, for: .popover)
        popupLayout.endPresentation()
    }

    /// 仅在浮层显示期间监听外部点击；本地菜单仍可正常跟踪，不拦截原始事件。
    private func installDismissMonitors(generation: UInt64) {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.isStatusItemClick(event) else { return }
                // 全局鼠标监听在主线程调用；同一事件内完成关闭，避免排队到下一次打开后。
                self.dismissIfCurrent(generation)
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocalClick(event) }
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                               object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            Task { @MainActor in self?.dismissIfCurrent(generation) }
        }
    }

    private func dismissIfCurrent(_ generation: UInt64) {
        guard generation == presentationGeneration else { return }
        hidePopup()
    }

    private func handleLocalClick(_ event: NSEvent) {
        if event.window === popup || event.window?.parent === popup { return }
        // 左右键均交给按钮的统一路由；监听器只负责真正的外部点击。
        if isStatusItemClick(event) { return }
        if let window = event.window, window.level >= .popUpMenu { return }
        hidePopup()
    }

    private func removeDismissMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        globalClickMonitor = nil
        localClickMonitor = nil
        activationObserver = nil
    }

    private func isStatusItemClick(_ event: NSEvent) -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return StatusItemInteraction.hitsButton(event: event, buttonFrame: frame)
    }

    @objc private func handleStatusItemAction() {
        let event = NSApp.currentEvent
        switch StatusItemInteraction.action(eventType: event?.type, modifiers: event?.modifierFlags ?? [],
                                            popupPresented: popupPresented) {
        case .showPanel: showPopup()
        case .hidePanel: hidePopup()
        case .showMenu: showStatusItemMenu()
        case nil: break
        }
    }

    private func showStatusItemMenu() {
        guard let button = statusItem.button else { return }
        // 右键只叠加菜单，不关闭已展开的主面板；关闭菜单后保留原页签和窗口位置。
        // 右键仅提供打开、设置与退出；不混入偏好开关和禁用的信息项。
        let menu = StatusItemMenu.make(openPanel: { [weak self] in self?.showPopup() },
                                       openSettings: { [weak self] in self?.showSettings() },
                                       quit: { NSApp.terminate(nil) },
                                       language: AppSettings.shared.resolvedLanguage)
        // 临时交给 NSStatusItem 的原生菜单路径，由 AppKit 选择屏幕、菜单栏下方的位置和高亮。
        // 普通 NSMenu.popUp 是视图弹出菜单，不具备状态栏菜单的锚定行为，可能覆盖菜单栏。
        statusItem.menu = menu
        defer {
            // 菜单跟踪结束即移除，保留左键打开浮层的既有行为。
            statusItem.menu = nil
            button.highlight(popupPresented)
        }
        button.performClick(nil)
    }

    private func updateStatusItemBattery() {
        guard let button = statusItem.button else { return }
        let settings = AppSettings.shared
        let candidate = model.menuBarBattery(for: settings.menuBarBatterySource)
        if settings.showMenuBarDeviceIcon == true,
           let systemName = model.menuBarDeviceSymbol() {
            button.image = AuxmoStatusIcon.device(systemName: systemName)
        } else {
            // 未开启设备图标或当前没有可用输出时，明确显示 Auxmo 品牌图标。
            button.image = AuxmoStatusIcon.make()
        }
        button.image?.accessibilityDescription = "Auxmo 音频控制"
        button.title = StatusItemBatteryText.title(reading: candidate?.reading)
        let actionHint = L10n.text("左键打开/收起，右键更多操作", language: settings.resolvedLanguage)
        if let candidate,
           let batteryTip = StatusItemBatteryText.toolTip(
               reading: candidate.reading,
               deviceName: candidate.displayName,
               language: settings.resolvedLanguage
           ) {
            button.toolTip = "\(batteryTip) · \(actionHint)"
            button.setAccessibilityValue(
                HeadphoneBatteryText.accessibility(candidate.reading, language: settings.resolvedLanguage)
            )
        } else {
            button.toolTip = "Auxmo · \(actionHint)"
            button.setAccessibilityValue(nil)
        }
    }

}

extension StatusPanelController: NSWindowDelegate {
    /// 拖拽边框时强制返回最小外框尺寸，覆盖 SwiftUI 宿主和旧窗口 frame 的影响。
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === mainWindow else { return frameSize }
        let minimum = sender.frameRect(forContentRect: NSRect(origin: .zero,
                                                               size: AuxmoDashboardWindow.minimumContentSize)).size
        return NSSize(width: min(max(frameSize.width, minimum.width), AuxmoDashboardWindow.maximumContentWidth),
                      height: max(frameSize.height, minimum.height))
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if notification.object as? NSWindow === popup, popupPresented,
           !popup.isVisible || NSApp.isHidden { hidePopup() }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === popup { hidePopup(); return }
        if notification.object as? NSWindow === mainWindow {
            AuxmoUpdateChecker.shared.resetSettingsPresentation()
            mainWindow?.orderOut(nil)
            // 关闭详情窗口不退出 Auxmo；退回 .accessory 移除 Dock 图标，同时不剥夺独立音效窗焦点。
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
/// 顶栏 44、标签区 36、页脚 34；显示时按当前屏幕的可用高度限制外框。
/// 测量的是中部完整内容，最小高度只给视口留余量，不放大每行控件。
enum PanelMetrics {
    // 与 Magpie 的 panelWidth 保持一致，菜单栏浮层使用 440pt 标准宽度。
    static let width: CGFloat = 440
    static let minimumHeight: CGFloat = 300
    /// 未展示的初始布局使用这个尺寸预算；展示时由控制器注入实际屏幕上限。
    static let maximumContentHeight: CGFloat = 560
    static let chromeHeight: CGFloat = 114
    static let contentWidth: CGFloat = width - 24
    // 主面板所有左右留白只由这一个常量决定；行内 padding 是唯一水平入口，
    // 外层容器不再叠加水平留白，避免左边出现双重缩进而右边只有一层。
    static let horizontalInset: CGFloat = 12
    static let deviceRowHeight: CGFloat = 40
    static let deviceSelectionWidth: CGFloat = 176
    static let compactSliderMinimumWidth: CGFloat = 136

    /// 独立窗口内容变化时保持左上角；不以中心缩放，也不让页脚变化带动整个窗口左右漂移。
    static func resizedWindowFrame(_ current: CGRect, size: CGSize) -> CGRect {
        CGRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height)
    }

    static func viewportHeight(contentHeight: CGFloat,
                               maximumHeight: CGFloat = chromeHeight + maximumContentHeight) -> CGFloat {
        // 小屏幕也不能被最小高度挤出屏幕；自然内容始终测全，只限制最终视口。
        let available = max(0, floor(maximumHeight) - chromeHeight)
        return min(max(minimumHeight - chromeHeight, ceil(contentHeight)), available)
    }

    static func size(contentHeight: CGFloat,
                     maximumHeight: CGFloat = chromeHeight + maximumContentHeight) -> CGSize {
        CGSize(width: width,
               height: viewportHeight(contentHeight: contentHeight, maximumHeight: maximumHeight) + chromeHeight)
    }
}


