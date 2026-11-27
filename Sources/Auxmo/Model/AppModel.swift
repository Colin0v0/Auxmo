import AppKit
import CoreAudio
import CoreGraphics
import SwiftUI
import OSLog
import AuxmoCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private static let audioLog = Logger(subsystem: "com.colin0v0.auxmo.app", category: "ApplicationAudio")
    /// 诊断事件只保留近期状态变化；容量与去重由日志对象统一约束。
    let diagnosticEventLog = DiagnosticEventLog()
    let headphones: HeadphoneControllerGroup
    private let observesHeadphones: Bool
    @Published private(set) var headphoneControl = HeadphoneControlSelection()
    @Published private(set) var audio: SystemAudioSnapshot?
    @Published private(set) var audioError: String? {
        didSet { recordDiagnosticChange("audio", old: oldValue, new: audioError) }
    }
    @Published private(set) var inputAudio: SystemInputSnapshot?
    @Published private(set) var inputError: String? {
        didSet { recordDiagnosticChange("input", old: oldValue, new: inputError) }
    }
    @Published private(set) var inputOperationError: String? {
        didSet { recordDiagnosticChange("inputOperation", old: oldValue, new: inputOperationError) }
    }
    @Published private(set) var applications: [ApplicationAudioRow] = []
    /// 展示列表独立于实时进程目录；切路由时保留行身份，不用短暂的停流驱动界面增删。
    @Published private(set) var playingApplications: [ApplicationAudioRow] = []
    /// 全局安全静音只在本次运行内有效；它叠加在每个 App 自己的静音意图之上。
    @Published private(set) var globalSafetyMuteEnabled = false
    @Published private(set) var registeredProcessCount = 0
    @Published private(set) var audioCaptureAccess: SystemAudioCaptureAccess = .notDetermined {
        didSet {
            guard oldValue != audioCaptureAccess else { return }
            diagnosticEventLog.record(category: "permission", message: audioCaptureAccess.rawValue)
        }
    }
    @Published private(set) var processError: String? {
        didSet { recordDiagnosticChange("process", old: oldValue, new: processError) }
    }
    @Published private(set) var mixStates: [String: ApplicationMixState] = [:]
    @Published private(set) var sessions: [String: any ApplicationAudioSession] = [:]
    // 配置所有权交给独立对象；AppModel 只协调已知配置与真实音频会话。
    let routes: StoredConfiguration<[String: AppAudioRoute]>
    let effects: ApplicationAudioEffectsLibrary
    var appAudioRoutes: [String: AppAudioRoute] { routes.value ?? [:] }
    var applicationRouteConfigurationAvailable: Bool { routes.available }
    var appAudioRoutePersistenceError: String? { routes.error }
    var appAudioEffects: [String: AppAudioEffectSettings] { effects.settings.value ?? [:] }
    var appAudioEffectCustomPresets: [AppAudioEffectCustomPreset] { effects.presets.value ?? [] }
    var appAudioEffectPersistenceError: String? { effects.error }
    var applicationEffectConfigurationAvailable: Bool { effects.settings.available }
    var applicationEffectPresetsAvailable: Bool { effects.presets.available }
    var bypassedApplicationAudioEffectKeys: Set<String> { effects.bypassedKeys }
    var applicationEffectsEnabled: Bool { effects.enabled }
    @Published var operationError: String? {
        didSet { recordDiagnosticChange("operation", old: oldValue, new: operationError) }
    }
    @Published private(set) var cleanupErrors: [String: String] = [:] {
        didSet { recordCleanupErrorChanges(from: oldValue) }
    }
    @Published private(set) var outputRouting = OutputRoutingState() {
        didSet { recordRoutingChange(from: oldValue) }
    }
    /// 引擎每次协调后产出的不可变音频拓扑计划与逐应用路由因果解释。
    @Published private(set) var audioGraphPlan: AudioGraphPlan = .empty
    var routeExplanations: [String: AudioRouteExplanation] { audioGraphPlan.explanations }
    func routeExplanation(for applicationID: String) -> AudioRouteExplanation? {
        audioGraphPlan.explanations[applicationID]
    }
    let audioEngine: AuxmoAudioEngine
    var multiOutputRoute: MultiOutputRoute? { outputRouting.confirmed?.aggregate }
    var multiOutputError: String? { outputRouting.error }
    var singleOutputTargetUID: String? {
        guard let confirmed = outputRouting.confirmed, confirmed.intent.isSimultaneous,
              confirmed.intent.memberUIDs.count == 1 else { return nil }
        return confirmed.output.uid
    }
    let routing: OutputRoutingController
    private let applicationEnvironment: ApplicationAudioEnvironment?
    var routingNow: Date {
        if let applicationEnvironment { return applicationEnvironment.now() }
        return Date()
    }
    private var routeConfirmationTimer: Timer?
    /// 蓝牙重连时 HAL 会在短时间内先切换默认句柄、后补齐输出流；只在这个有界窗口内等待收敛。
    private var pendingAudioSnapshotDeadline: Date?
    private var sessionRouteWaitSince: [String: Date] = [:]
    /// 仅用于界面稳定：路由确认后给音频进程三秒重新注册，绝不用于创建或保活音频会话。
    private var applicationListSettleDeadline: Date?
    /// 用户明确要求的 APP 重试绑定到这一次目标路由；HAL 尚未确认时不清错、不提前建会话。
    private var pendingApplicationReapplies: [String: OutputRoutingIntent] = [:]
    /// 恢复凭据绑定原会话、进程和精确播放路径，不用错误字符串猜测清错资格。
    private struct ProcessReadRecovery {
        let sessionID: ObjectIdentifier
        let group: AudioProcessGroup
        let route: ApplicationPlaybackRoute
        let storedRoute: AppAudioRoute
    }
    private var processReadRecoveries: [String: ProcessReadRecovery] = [:]
    let outputHardware: MultiOutputHardware
    private let monitorsSystem: Bool
    private var timer: Timer?
    /// 静音下发与短周期发现的所有权独立于音频路由协调。
    private let safetyMute = GlobalSafetyMuteController()
    let deviceMuteConfirmations = DeviceMuteConfirmationController()
    private let metering = ApplicationMeterController()
    /// 本机音频统计只记录已确认的活跃应用与输出设备，数据保存在用户本地。
    let listeningStatistics = ListeningStatisticsStore()
    private var metersVisible: Bool { metering.visible }
    /// 只有当前显示麦克风页的可见面板才需要枚举输入设备；隐藏页不因全局静音轮询反复读取 HAL。
    private(set) var inputControlsVisibleSurfaces: Set<MeterSurface> = []
    private var shouldRefreshInputs: Bool {
        InputRefreshPolicy.isNeeded(monitorsSystem: monitorsSystem,
                                    selectedSurfaces: inputControlsVisibleSurfaces,
                                    visibleSurfaces: metering.visibleSurfacesSnapshot)
    }
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var outputRouteListener: AudioObjectPropertyListenerBlock?
    private var mediaOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var systemOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private enum Lifecycle { case running, stopping, stopped }
    private var lifecycle: Lifecycle = .running
    var isShutdown: Bool { lifecycle == .stopped }
    var isShuttingDown: Bool { lifecycle == .stopping }
    private var shutdownRouteRequested = false
    /// 退出只做一次兜底扫描；取消退出后再次点击退出必须重新读取 HAL。
    private var shutdownSweepCompleted = false
    private var isReconcilingBatch = false

    /// 权限撤销后仍必须允许关闭全局静音，不能把用户困在已开启状态。
    var canChangeGlobalSafetyMute: Bool {
        globalSafetyMuteEnabled
            || (applicationRouteConfigurationAvailable
                && audioCaptureAccess.allowsApplicationAudio
                && !applicationAudioUnavailable)
    }

    /// 正式应用在主线程显式取得 HAL，避免默认参数在非隔离上下文读取主线程状态。
    convenience init(startsMonitoring: Bool = true) {
        self.init(outputHardware: .live, startsMonitoring: startsMonitoring,
                  appAudioEffectsEnabled: AppSettings.shared.appAudioEffectsEnabled == true)
    }

    /// 测试可注入只驻留内存的 HAL，并关闭系统监听，避免测试修改用户的音频设置。
    init(outputHardware: MultiOutputHardware, startsMonitoring: Bool = true,
         applicationAudio: ApplicationAudioEnvironment? = nil,
         audioEngine: AuxmoAudioEngine? = nil,
         headphoneControllerFactory: (() -> HeadphoneController)? = nil,
         userIsSelectingOutput: (() -> Bool)? = nil,
         appAudioRouteStore: AppAudioRouteStore? = nil,
         appAudioEffectStore: AppAudioEffectStore? = nil,
         appAudioEffectsEnabled: Bool = false) {
        let engine = audioEngine ?? AuxmoAudioEngine()
        self.audioEngine = engine
        if let headphoneControllerFactory {
            self.headphones = HeadphoneControllerGroup(makeController: headphoneControllerFactory)
        } else { self.headphones = HeadphoneControllerGroup() }
        self.observesHeadphones = startsMonitoring || headphoneControllerFactory != nil
        self.outputHardware = outputHardware
        self.monitorsSystem = startsMonitoring
        let routeStore = appAudioRouteStore ?? AppAudioRouteStore()
        self.routes = StoredConfiguration(read: routeStore.load, write: routeStore.save)
        let effectStore = appAudioEffectStore ?? AppAudioEffectStore()
        self.effects = ApplicationAudioEffectsLibrary(store: effectStore, enabled: appAudioEffectsEnabled)
        if let applicationAudio { self.applicationEnvironment = applicationAudio }
        else if startsMonitoring { self.applicationEnvironment = .live(engine: engine) }
        else { self.applicationEnvironment = nil }
        routing = OutputRoutingController(hardware: outputHardware)
        routing.localPlaybackOnConfirmedRoute = { [weak self] in
            guard let self, let confirmed = self.outputRouting.confirmed else { return false }
            return self.sessions.values.contains { $0.output.uid == confirmed.output.uid && $0.isActive }
        }
        routing.isUserSelectingOutput = userIsSelectingOutput ?? SystemOutputPicker.isInUse
        routing.beforeChanging = { [weak self] in
            guard let self else { return }
            self.processReadRecoveries.removeAll()
            try self.suspendApplicationsForOutputChange()
            self.sessionRouteWaitSince.removeAll()
        }
        routing.beforeAdoptingUnexpectedOutput = { [weak self] output in
            guard let self else { return }
            // 写入后尚未读回的情况交回路由事务等待，不把它伪装成成功，也不立即锁存永久失败。
            do { try self.outputHardware.setMute(true, output.id) }
            catch let pending as AudioDeviceMutePending {
                self.diagnosticEventLog.record(category: "outputProtection", message: "unexpected output mute awaiting confirmation: \(output.uid)")
                throw pending
            }
            self.diagnosticEventLog.record(category: "outputProtection", message: "unexpected output muted: \(output.uid)")
        }
        routing.didChange = { [weak self] state in
            guard let self else { return }
            let wasBusy = self.outputRouting.phase.isBusy
            let beganSwitch = !wasBusy && state.phase.isBusy
            let finishedSwitch = wasBusy && !state.phase.isBusy && state.phase != .failed
            let changedRoute = self.outputRouting.confirmed != nil && state.confirmed != nil
                && self.outputRouting.confirmed?.output.uid != state.confirmed?.output.uid
            if beganSwitch || finishedSwitch || changedRoute {
                self.applicationListSettleDeadline = self.routingNow.addingTimeInterval(3)
            }
            if state.phase == .failed { self.applicationListSettleDeadline = nil }
            if self.outputRouting != state { self.outputRouting = state }
        }
        // 转发只读配置状态的变更，不再由 AppModel 同时维护第二份可写集合。
        routes.willChange = { [weak self] in self?.objectWillChange.send() }
        effects.willChange = { [weak self] in self?.objectWillChange.send() }
        effects.settings.willChange = { [weak self] in self?.objectWillChange.send() }
        effects.presets.willChange = { [weak self] in self?.objectWillChange.send() }
        for (category, recordError) in [("appAudioRoutePersistence", routes.error),
                                        ("appAudioEffectPersistence", effects.settings.error),
                                        ("appAudioPresetPersistence", effects.presets.error)] {
            if let recordError { diagnosticEventLog.record(category: category, message: recordError) }
        }
        routes.errorDidChange = { [weak self] error in
            self?.diagnosticEventLog.record(category: "appAudioRoutePersistence", message: error ?? "cleared")
        }
        effects.settings.errorDidChange = { [weak self] error in
            self?.diagnosticEventLog.record(category: "appAudioEffectPersistence", message: error ?? "cleared")
        }
        effects.presets.errorDidChange = { [weak self] error in
            self?.diagnosticEventLog.record(category: "appAudioPresetPersistence", message: error ?? "cleared")
        }
        refresh()
        diagnosticEventLog.record(category: "lifecycle",
                                  message: "launched Auxmo \(AuxmoVersion.current)")
        guard monitorsSystem else { return }
        // 从系统设置返回后复查授权，不信任首次启动的“已经申请过”标记。
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        installOutputRouteListener()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshForPeriodicTimer() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShuttingDown, !self.isShutdown else { return }
                self.diagnosticEventLog.record(category: "lifecycle", message: "system will sleep")
                self.listeningStatistics.persist()
                self.headphones.suspend()
                self.pauseManagedApplicationsForSleep()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShutdown, !self.isShuttingDown else { return }
                self.diagnosticEventLog.record(category: "lifecycle", message: "system did wake")
                self.headphones.resume()
                // 先读取唤醒后的真实输出，再恢复睡眠暂停的应用，避免把旧设备 UID 重新绑定回来。
                self.refresh()
                self.recoverApplicationsPausedForSleep()
                self.refresh()
            }
        }
    }

    private func recordDiagnosticChange(_ category: String, old: String?, new: String?) {
        guard old != new else { return }
        diagnosticEventLog.record(category: category, message: new ?? "cleared")
    }

    private func recordCleanupErrorChanges(from previous: [String: String]) {
        for key in Set(previous.keys).union(cleanupErrors.keys).sorted() {
            guard previous[key] != cleanupErrors[key] else { continue }
            if let message = cleanupErrors[key] {
                diagnosticEventLog.record(category: "cleanup", message: "\(key): \(message)")
            } else {
                diagnosticEventLog.record(category: "cleanup", message: "\(key): cleared")
            }
        }
    }

    private func recordRoutingChange(from previous: OutputRoutingState) {
        guard previous.phase != outputRouting.phase
                || previous.error != outputRouting.error
                || previous.warning != outputRouting.warning
                || previous.confirmed?.output.uid != outputRouting.confirmed?.output.uid
                || previous.actualOutput?.uid != outputRouting.actualOutput?.uid else {
            return
        }
        var parts = ["phase=\(outputRouting.phase.diagnosticDescription)"]
        if let output = outputRouting.confirmed?.output {
            parts.append("confirmed=\(output.uid)")
        }
        if let output = outputRouting.actualOutput {
            parts.append("actual=\(output.uid)")
        }
        if let error = outputRouting.error {
            parts.append("error=\(error)")
        }
        if let warning = outputRouting.warning {
            parts.append("warning=\(warning)")
        }
        diagnosticEventLog.record(category: "routing", message: parts.joined(separator: " | "))
    }

    /// 蓝牙重连可能瞬间改写默认输出。监听 HAL 通知后立即纠正，不能只等两秒轮询。
    private func installOutputRouteListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshForPeriodicTimer() }
        }
        outputRouteListener = listener
        _ = AudioObjectAddPropertyListenerBlock(HAL.system, &mediaOutputAddress, DispatchQueue.main, listener)
        _ = AudioObjectAddPropertyListenerBlock(HAL.system, &systemOutputAddress, DispatchQueue.main, listener)
    }

    private func removeOutputRouteListener() {
        guard let outputRouteListener else { return }
        _ = AudioObjectRemovePropertyListenerBlock(HAL.system, &mediaOutputAddress,
                                                   DispatchQueue.main, outputRouteListener)
        _ = AudioObjectRemovePropertyListenerBlock(HAL.system, &systemOutputAddress,
                                                   DispatchQueue.main, outputRouteListener)
        self.outputRouteListener = nil
    }

    func refresh() {
        guard !isShutdown, !isShuttingDown else { return }
        refreshAudio()
        guard applicationEnvironment != nil, pendingAudioSnapshotDeadline == nil,
              !routing.hasPendingObservation else { return }
        refreshApplicationState()
    }

    /// 隐藏且没有用户管理的音频会话时，周期任务只刷新输出路由；
    /// 进程归属和输入设备枚举留给面板打开或用户主动操作，避免空闲时反复做完整扫描。
    private func refreshForPeriodicTimer() {
        guard !isShutdown, !isShuttingDown else { return }
        refreshAudio()
        guard applicationEnvironment != nil, shouldRefreshApplicationStateDuringPolling,
              pendingAudioSnapshotDeadline == nil, !routing.hasPendingObservation else { return }
        refreshApplicationState()
    }

    private var shouldRefreshApplicationStateDuringPolling: Bool {
        true // 统计需要持续观察活跃音频应用，即使统计页面当前没有打开。
    }

    private func refreshApplicationState() {
        guard !isShutdown, !isShuttingDown else { return }
        guard let applicationEnvironment else { return }
        refreshAudioCaptureAccess()
        if shouldRefreshInputs { refreshInputs() }
        var didReadApplications = false
        do {
            let retained = Set(mixStates.keys.filter { mixStates[$0]?.managed == true || sessions[$0] != nil })
            let observation = try applicationEnvironment.readApplications(retained)
            if registeredProcessCount != observation.processCount { registeredProcessCount = observation.processCount }
            let nextApplications = observation.rows
            if applications != nextApplications { applications = nextApplications }
            updateApplicationList(from: nextApplications)
            prepareLevelSources(for: playingApplications)
            if processError != nil { processError = nil }
            didReadApplications = true
        } catch {
            // 枚举失败就报告失败并暂停；不换另一份进程来源，也不把读取失败伪装成零个进程。
            metering.clearAll()
            if processError != error.localizedDescription { processError = error.localizedDescription }
            pauseForProcessReadFailure(error)
        }
        // 轮询结果未变化时不能写回 @Published 字典，否则整个面板会每两秒无意义重算一次。
        var nextMixStates = mixStates
        var mixStatesChanged = false
        for app in applications where nextMixStates[app.id] == nil {
            nextMixStates[app.id] = ApplicationMixState()
            mixStatesChanged = true
        }
        // 每次只读刷新都重新检查冲突事实，不把上一次错误当作当前进程仍存活的证据。
        let fineTuneRunning = isFineTuneRunning
        for key in Array(nextMixStates.keys) {
            guard var state = nextMixStates[key] else { continue }
            let previous = state
            state.updateFineTuneAvailability(isRunning: fineTuneRunning)
            if state != previous {
                nextMixStates[key] = state
                mixStatesChanged = true
            }
        }
        if mixStatesChanged { mixStates = nextMixStates }
        if processError == nil { recoverProcessReadFailures() }
        reconcileSessions()
        if didReadApplications {
            recordListeningStatisticsFromEngine()
        }
    }

    private func recordListeningStatisticsFromEngine() {
        guard let snapshot = audio, !outputRouting.phase.isBusy, outputRouting.phase != .failed,
              snapshot.outputs.contains(where: { $0.id == snapshot.selectedID }) else {
            // 未确认系统输出时结束本次采样，不能把等待时间算到下次恢复后的设备。
            listeningStatistics.record(at: routingNow, observations: [])
            return
        }
        let unavailable = Set(outputRouting.unavailableMemberUIDs)
        let activeOutputs = snapshot.outputs.filter { !$0.isAggregate && !unavailable.contains($0.uid) }
        let observations = applications.filter(\.isRunningOutput).map { app in
            let outputs: [AudioOutput]
            if let session = sessions[app.id], session.mode == .mixing {
                if session.isActive && !session.isSuspendedForOutputChange {
                    let actualUIDs = Set(session.playbackRoute.playbackDeviceUIDs)
                    outputs = activeOutputs.filter { actualUIDs.contains($0.uid) }
                } else {
                    outputs = []
                }
            } else {
                outputs = audioGraphPlan.activeOutputs(for: app.id, onlineOutputs: activeOutputs)
            }
            return ListeningPlaybackObservation(application: app, outputs: outputs)
        }
        listeningStatistics.record(at: routingNow, observations: observations)
    }

    /// 权限由独立提示控制器展示，不向每个应用锁存同一条错误。
    /// 撤销权限时先停止静音/重放会话，保留音量与路由意图；授权后再重新协调。
    @discardableResult
    func refreshAudioCaptureAccess() -> Bool {
        guard let applicationEnvironment else { return false }
        let access = applicationEnvironment.captureAccess()
        if audioCaptureAccess != access { audioCaptureAccess = access }
        if !access.allowsApplicationAudio {
            for key in Array(sessions.keys) where cleanupErrors[key] == nil { stop(key) }
            metering.clearAll()
        }
        return access.allowsApplicationAudio
    }

    @discardableResult
    func openAudioCaptureSettings() -> Bool {
        if !NSWorkspace.shared.open(AudioCapturePermissionAlert.systemSettingsURL) {
            operationError = "未能打开系统设置，请手动进入隐私与安全性 → 屏幕与系统音频录制。"
            return false
        }
        return true
    }

    private func prepareLevelSources(for rows: [ApplicationAudioRow]) { metering.prepare(for: rows) }

    /// 界面和 APP 只消费阶段机确认过的事实，刷新本身不抢回任何外部默认输出。
    func refreshAudio() {
        do {
            let fresh = try outputHardware.snapshot()
            pendingAudioSnapshotDeadline = nil
            let previous = outputRouting.confirmed
            routing.observe(fresh, at: routingNow)
            if routing.hasPendingObservation {
                // 尚未确认路由事实，撤销旧界面和播放会话的使用资格。
                suspendUncertainAudioObservation()
                updateRouteConfirmationActivity()
                return
            }
            guard let observed = routing.latestSnapshot else { throw AudioFailure("无法读回当前路由快照") }
            if audio != observed { audio = observed }
            audioEngine.updatePhysicalOutputs(observed.outputs)
            if audioError != nil { audioError = nil }
            if let confirmed = outputRouting.confirmed, !outputRouting.phase.isBusy {
                // 路由请求可能在一次硬件读回内直接确认，不能让 APP 仍绑定旧输出后误判为外部变化。
                // rebind 本身只修改发生变化的托管行，不会在每轮轮询里重复发布状态。
                rebindManagedApplications(to: confirmed.output.uid)
                if previous != confirmed {
                    sessionRouteWaitSince.removeAll()
                    if outputRouting.phase == .stable { pendingApplicationReapplies.removeAll() }
                }
                // 明确请求确认后，以及外部媒体路由变化后，都跟随真实目标；真实 APP 错误仍不清除。
                if outputRouting.phase == .confirmed { completePendingApplicationReapplies(on: confirmed) }
            } else {
                // 切换期和失败态都优先保留静音 tap。
                // 非用户主动停止时销毁 tap 会立即恢复 App 原声，比短暂无声更危险。
                for key in Array(sessions.keys) where cleanupErrors[key] == nil {
                    if outputRouting.phase.isBusy,
                       (sessions[key]?.isSuspendedForOutputChange == true
                        || sessions[key]?.supportsContinuousOutputSwitch == true) {
                        continue
                    }
                    _ = preserveMixingSession(key)
                }
                if outputRouting.phase == .failed {
                    pendingApplicationReapplies.removeAll()
                    for key in Array(mixStates.keys) where mixStates[key]?.managed == true && mixStates[key]?.failure == nil {
                        markApplicationOutputChanged(for: key)
                    }
                }
            }
            if observesHeadphones { updateHeadphoneControl(from: observed) }
            updateRouteConfirmationActivity()
        } catch {
            // 切换中的旧对象尚未从 HAL 列表移除时，继续由同一阶段和原期限确认，不能锁存全局失败。
            if routing.deferPendingObservation(error, at: routingNow) {
                updateRouteConfirmationActivity()
                return
            }
            // 被动上下线没有用户操作失败：静默等待真实设备枚举恢复。
            // 三秒内快速观察，之后仅使用常规轮询，避免设备离线时一直高频刷新。
            if error is AudioSnapshotPending, !outputRouting.phase.isBusy {
                suspendUncertainAudioObservation()
                if pendingAudioSnapshotDeadline == nil {
                    pendingAudioSnapshotDeadline = routingNow.addingTimeInterval(3)
                }
                updateRouteConfirmationActivity()
                return
            }
            // who? 是属性不可读，不是 !obj。设备重新注册时可能短暂返回这个值；
            // 只在同一次只读快照的三秒窗口内等待，持续缺属性仍按真实失败报告。
            if let failure = error as? AudioFailure,
               failure.status == kAudioHardwareUnknownPropertyError,
               !outputRouting.phase.isBusy, outputRouting.phase != .failed {
                if pendingAudioSnapshotDeadline == nil {
                    pendingAudioSnapshotDeadline = routingNow.addingTimeInterval(3)
                }
                if let until = pendingAudioSnapshotDeadline, routingNow < until {
                    suspendUncertainAudioObservation()
                    updateRouteConfirmationActivity()
                    return
                }
            }
            pendingAudioSnapshotDeadline = nil
            routing.observationFailed(error)
            pendingApplicationReapplies.removeAll()
            updateRouteConfirmationActivity()
            if audio != nil { audio = nil }
            audioEngine.updatePhysicalOutputs([])
            if audioError != error.localizedDescription { audioError = error.localizedDescription }
            headphoneControl = HeadphoneControlSelection()
            headphones.outputUnavailable()
            pauseManagedApplications("系统音频状态读取失败：\(error.localizedDescription)")
            refreshAudioGraphPlan()
        }
    }

    /// 系统快照不可信时不展示旧设备，也不让已接管会话继续持有旧播放路由。
    /// 资源释放失败沿用现有清理错误，不能静默掩盖。
    private func suspendUncertainAudioObservation() {
        if audio != nil { audio = nil }
        audioEngine.updatePhysicalOutputs([])
        headphoneControl = HeadphoneControlSelection()
        if observesHeadphones { headphones.outputUnavailable() }
        // 快照暂时不可信只撤销旧路由的使用资格，不销毁正在静音的 tap。
        for key in Array(sessions.keys) where cleanupErrors[key] == nil {
            _ = preserveMixingSession(key)
        }
        refreshAudioGraphPlan()
    }

    /// 只在等待 HAL 时短周期读取同一目标；不重复发出写请求，也不阻塞 UI 主线程。
    private func updateRouteConfirmationActivity() {
        guard monitorsSystem,
              outputRouting.phase.isBusy
                || routing.hasPendingRelease && outputRouting.phase != .failed
                || pendingAudioSnapshotDeadline.map({ routingNow < $0 }) == true
                || routing.needsFastObservation(at: routingNow) else {
            routeConfirmationTimer?.invalidate(); routeConfirmationTimer = nil
            return
        }
        guard routeConfirmationTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShutdown, !self.isShuttingDown else { return }
                self.refreshAudio()
                // 过渡期间只观察路由；不能以 20Hz 反复枚举全部 APP、输入设备或启动 tap。
                if !self.outputRouting.phase.isBusy, !self.routing.hasPendingRelease,
                   self.pendingAudioSnapshotDeadline == nil, !self.routing.hasPendingObservation,
                   self.applicationEnvironment != nil {
                    self.refreshApplicationState()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        routeConfirmationTimer = timer
    }

    /// 耳机页与驱动共用全部可控物理设备；播放路由切换不撤销仍在线耳机的控制资格。
    private func updateHeadphoneControl(from snapshot: SystemAudioSnapshot) {
        var next = headphoneControl
        next.update(snapshot: snapshot, supports: { headphones.supports($0) })
        if next != headphoneControl { headphoneControl = next }
        headphones.updateOutputs(next.candidates)
    }

    private func refreshInputs() {
        do {
            let nextInput = try SystemInput.snapshot()
            if inputAudio != nextInput { inputAudio = nextInput }
            if inputError != nil { inputError = nil }
        } catch {
            if inputAudio != nil { inputAudio = nil }
            if inputError != error.localizedDescription { inputError = error.localizedDescription }
        }
    }

    private var isFineTuneRunning: Bool { applicationEnvironment?.hasMixerConflict() == true }

    /// 只稳定列表展示，不改变实时目录中的播放标记和进程对象，不能让旧流获得写入资格。
    private func updateApplicationList(from rows: [ApplicationAudioRow]) {
        let active = ApplicationCatalog.playingRows(from: rows)
        let activeIDs = Set(active.map(\.id))
        let current = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let settling = outputRouting.phase.isBusy
            || applicationListSettleDeadline.map { routingNow < $0 } == true
        if !settling { applicationListSettleDeadline = nil }

        // 已有行保持相对顺序，新播放的应用追加；切换窗口内的短暂停流不触发行的移除动画。
        var next = playingApplications.compactMap { previous -> ApplicationAudioRow? in
            guard settling || activeIDs.contains(previous.id) else { return nil }
            if let observed = current[previous.id] { return observed }
            // 只保留图标与名称，明确撤销已消失的流，不用旧 group 冒充当前进程。
            return ApplicationAudioRow(id: previous.id, bundleID: previous.bundleID,
                                       name: previous.name, applicationURL: previous.applicationURL,
                                       group: nil, isRunningOutput: false)
        }
        let retainedIDs = Set(next.map(\.id))
        next.append(contentsOf: active.filter { !retainedIDs.contains($0.id) })
        if playingApplications != next { playingApplications = next }
    }

    func levelSource(for applicationID: String) -> ApplicationLevelSource { metering.source(for: applicationID) }

    var unmanagedMultiOutputs: [AudioOutput] {
        guard let audio else { return [] }
        return routing.unmanagedOutputs(in: audio)
    }

    var applicationAudioUnavailableReason: String? {
        // 正在离开或重建 Auxmo 组合时，不能用中间默认设备把整个 APP 区替换成限制文案。
        if outputRouting.phase.isBusy, !playingApplications.isEmpty { return nil }
        guard let output = selectedOutput, output.isAggregate else { return nil }
        if output.isAuxmoMultiOutput, output.uid != multiOutputRoute?.uid {
            return "选择上面的扬声器后，可调节 APP 音量与电平"
        }
        if output.uid == multiOutputRoute?.uid {
            // 当前 Auxmo 聚合有完整成员信息，APP 捕获与重放会走多设备镜像路由。
            return nil
        }
        // 外部聚合输出也不能送入只支持单设备的处理链；只说明限制，不再要求用户先选扬声器。
        return "当前系统输出不支持 APP 独立音量与电平"
    }

    var applicationAudioUnavailable: Bool { applicationAudioUnavailableReason != nil }

    func reloadApplicationAudioEffects() {
        processReadRecoveries.removeAll()
        pendingApplicationReapplies.removeAll()
        effects.reload()
        refresh()
    }

    private func pauseForProcessReadFailure(_ error: Error) {
        pendingApplicationReapplies.removeAll()
        let status = (error as? AudioFailure)?.status
        let recoverable = status == kAudioHardwareUnknownPropertyError || status == HAL.badObjectStatus
        let message = "音频进程读取失败：\(error.localizedDescription)"
        for key in Array(mixStates.keys) where mixStates[key]?.managed == true {
            guard let state = mixStates[key] else { continue }
            if state.failure == nil {
                if recoverable, let session = sessions[key], session.mode == .mixing,
                   !session.group.bundleID.isEmpty, cleanupErrors[key] == nil,
                   let storedRoute = applicationAudioRoute(for: key) {
                    processReadRecoveries[key] = ProcessReadRecovery(
                        sessionID: ObjectIdentifier(session), group: session.group,
                        route: session.playbackRoute, storedRoute: storedRoute)
                    mixStates[key]?.markProcessReadFailure(message)
                    diagnosticEventLog.record(category: "applicationFailure", message: "\(key): \(message)")
                } else { latchApplicationFailure(message, for: key) }
            } else if case .processRead = state.failureReason {
                if !recoverable { latchApplicationFailure(message, for: key) }
                // 同一次观察故障持续多久都不替换原凭据，也不覆盖后来出现的其他失败。
            }
        }
        for key in Array(sessions.keys) where cleanupErrors[key] == nil {
            _ = preserveMixingSession(key)
        }
    }

    /// 必须同时读回进程与确认路由；只清掉当前会话自己的只读故障，不重建 tap。
    private func recoverProcessReadFailures() {
        guard applicationRouteConfigurationAvailable,
              audio != nil, audioCaptureAccess.allowsApplicationAudio,
              !isFineTuneRunning, !outputRouting.phase.isBusy, outputRouting.phase != .failed,
              let confirmed = outputRouting.confirmed else { return }
        for (key, recovery) in processReadRecoveries {
            guard case .processRead = mixStates[key]?.failureReason else {
                processReadRecoveries.removeValue(forKey: key)
                continue
            }
            guard cleanupErrors[key] == nil,
                  let app = applications.first(where: { $0.id == key }), let group = app.group,
                  group.id == recovery.group.id, group.bundleID == recovery.group.bundleID,
                  Set(group.objectIDs) == Set(recovery.group.objectIDs),
                  let session = sessions[key], ObjectIdentifier(session) == recovery.sessionID,
                  session.isSuspendedForOutputChange, !session.isActive,
                  confirmed.output.uid == recovery.route.sourceOutputUID,
                  applicationAudioRoute(for: key) == recovery.storedRoute,
                  !effectiveApplicationAudioRoute(for: key).isWaitingForDevices,
                  let expected = try? applicationPlaybackRoute(for: confirmed.output, appID: key)
                        ?? .single(confirmed.output),
                  expected == recovery.route else { continue }
            mixStates[key]?.recoverProcessReadFailure()
            processReadRecoveries.removeValue(forKey: key)
            sessionRouteWaitSince.removeValue(forKey: key)
            diagnosticEventLog.record(category: "applicationRecovery", message: "\(key): process observation recovered")
        }
    }

    private func pauseManagedApplications(_ reason: String) {
        processReadRecoveries.removeAll()
        // 进程读取失败撤销旧的重试授权，不能在确认后把后来发生的真实错误清掉。
        pendingApplicationReapplies.removeAll()
        for key in Array(mixStates.keys) where mixStates[key]?.managed == true {
            latchApplicationFailure(reason, for: key)
        }
        // 暂停不等于释放：mixing tap 必须保留，等待明确的错误恢复路径处理。
        for key in Array(sessions.keys) where cleanupErrors[key] == nil {
            _ = preserveMixingSession(key)
        }
    }

    /// 睡眠是系统生命周期事件，不是应用处理失败；保留静音 tap 并单独记录可恢复状态。
    private func pauseManagedApplicationsForSleep() {
        processReadRecoveries.removeAll()
        pendingApplicationReapplies.removeAll()
        for key in Array(mixStates.keys) where mixStates[key]?.managed == true {
            mixStates[key]?.markSystemSleepPaused()
        }
        for key in Array(sessions.keys) where cleanupErrors[key] == nil {
            _ = preserveMixingSession(key)
        }
    }

    /// 唤醒后只恢复由本次睡眠标记的应用，不清除权限、路由或会话健康检查产生的真实错误。
    private func recoverApplicationsPausedForSleep() {
        guard let outputUID = outputRouting.confirmed?.output.uid else { return }
        for key in Array(mixStates.keys) {
            guard mixStates[key]?.failureReason == .systemSleep else { continue }
            mixStates[key]?.recoverSystemSleep(outputUID: outputUID)
            sessionRouteWaitSince.removeValue(forKey: key)
        }
    }

    /// 切换输出前保留混音会话的 tap，并解除设备绑定，让静音覆盖系统默认输出切换。
    private func suspendApplicationsForOutputChange() throws {
        for key in Array(sessions.keys) {
            guard cleanupErrors[key] == nil, let session = sessions[key] else { continue }
            if session.isSuspendedForOutputChange { continue }
            guard session.mode == .mixing, session.isActive else {
                guard stop(key) else { throw AudioFailure("旧 APP 音频资源尚未释放，未切换输出") }
                continue
            }
            if session.supportsContinuousOutputSwitch { continue }
            do {
                try session.suspendForOutputChange()
            } catch {
                cleanupErrors[key] = "\(session.group.label)：\(error.localizedDescription)"
                latchApplicationFailure("音频资源未能暂停，请点击重试释放。", for: key)
                throw AudioFailure("旧 APP 音频资源尚未暂停，未切换输出")
            }
        }
    }

    /// 非用户主动停止时保留 mixing tap，只拆除重放端。
    /// metering 会话不影响原声，仍可按普通资源释放；真正需要销毁 tap 的入口必须显式调用 stop。
    @discardableResult
    private func preserveMixingSession(_ key: String) -> Bool {
        guard let session = sessions[key] else { return true }
        guard session.mode == .mixing else { return stop(key) }
        if session.isSuspendedForOutputChange { return true }
        do {
            try session.suspendForOutputChange()
            return true
        } catch {
            cleanupErrors[key] = "\(session.group.label)：\(error.localizedDescription)"
            latchApplicationFailure("音频资源未能暂停，请点击重试释放。", for: key)
            return false
        }
    }

    private func reconcileSessions() {
        isReconcilingBatch = true
        defer {
            isReconcilingBatch = false
            _ = try? audioEngine.releaseIdleSinks()
            refreshAudioGraphPlan()
        }
        let visible = Set(applications.map(\.id))
        for key in Array(sessions.keys) where !visible.contains(key) && cleanupErrors[key] == nil { stop(key) }
        for key in Array(mixStates.keys) where !visible.contains(key) && (key.hasPrefix("pid:") || key.hasPrefix("unassigned:pid:")) {
            latchApplicationFailure("匿名音频进程已退出，请确认来源后重新应用。", for: key)
        }
        for app in applications { reconcile(app) }
    }

    func refreshAudioGraphPlan() {
        var effectiveEffectsMap: [String: AppAudioEffectSettings] = [:]
        for app in applications where !app.bundleID.isEmpty {
            let storageKey = "bundle:\(app.bundleID)"
            if let effect = effects.effective(for: storageKey) {
                effectiveEffectsMap[storageKey] = effect
            }
        }
        let configured = outputRouting.configured?.memberUIDs
            ?? outputRouting.confirmed?.intent.memberUIDs
            ?? []
        let world = AudioEngineWorld(
            excludedPID: audioEngine.excludedPID,
            captureAccess: audioCaptureAccess,
            routeConfigurationAvailable: applicationRouteConfigurationAvailable,
            effectConfigurationAvailable: applicationEffectConfigurationAvailable,
            effectsEnabled: applicationEffectsEnabled,
            hasMixerConflict: isFineTuneRunning,
            globalSafetyMute: globalSafetyMuteEnabled,
            metersVisible: metersVisible,
            routingPolicy: .authorizedGroupOnly,
            audioSnapshot: audio,
            confirmedRoute: outputRouting.confirmed,
            multiOutputRoute: multiOutputRoute,
            routingBusy: outputRouting.phase.isBusy,
            routingFailed: outputRouting.phase == .failed,
            configuredMemberUIDs: configured,
            unavailableMemberUIDs: Set(outputRouting.unavailableMemberUIDs),
            processReadError: processError,
            applications: applications,
            mixStates: mixStates,
            storedRoutes: appAudioRoutes,
            effectiveEffects: effectiveEffectsMap,
            existingSessionModes: sessions.mapValues(\.mode),
            cleanupErrorIDs: Set(cleanupErrors.keys)
        )
        let nextPlan = audioEngine.compilePlan(world)
        if audioGraphPlan != nextPlan {
            audioGraphPlan = nextPlan
        }
    }

    func reconcile(_ app: ApplicationAudioRow) {
        guard !isShutdown, !isShuttingDown else { return }
        defer {
            if !isReconcilingBatch {
                _ = try? audioEngine.releaseIdleSinks()
                refreshAudioGraphPlan()
            }
        }
        guard applicationRouteConfigurationAvailable else {
            // 未知配置不等于全部输出；已有 mixing tap 只暂停重放，不释放原声静音。
            if cleanupErrors[app.id] == nil { _ = preserveMixingSession(app.id) }
            return
        }
        guard audioCaptureAccess.allowsApplicationAudio else { return }
        guard var state = mixStates[app.id], cleanupErrors[app.id] == nil else { return }
        guard audio != nil, !outputRouting.phase.isBusy, outputRouting.phase != .failed,
              let confirmed = outputRouting.confirmed,
              processError == nil else {
            // 切换中、失败态或进程读取暂时不可信时，mixing 会话只能暂停重放，
            // 不能销毁 tap；否则用户正在静音或压低音量的 App 会立即恢复原声。
            if let session = sessions[app.id], session.mode == .mixing {
                if outputRouting.phase.isBusy, session.supportsContinuousOutputSwitch { return }
                _ = preserveMixingSession(app.id)
                return
            }
            stop(app.id)
            return
        }
        let output = confirmed.output
        let effectiveRoute = effectiveApplicationAudioRoute(for: app.id)
        if effectiveRoute.isWaitingForDevices {
            holdApplicationForUnavailableRoute(app, output: output, state: state)
            return
        }
        if output.isAggregate {
            // 只有本进程刚建立、且仍与当前快照一致的 Auxmo 聚合才能被接管；
            // 第三方聚合和上次启动遗留的聚合都缺少可信成员镜像，不能猜测音频路线。
            guard let route = multiOutputRoute,
                  route.deviceID == output.id,
                  route.uid == output.uid else {
                if state.managed {
                    latchApplicationFailure("当前组合输出没有可用的 Auxmo 路由，请结束组合后重新应用。", for: app.id)
                }
                stop(app.id)
                return
            }
        }
        let requiresRouting = effectiveRoute.isCustom
        let effect = effectiveApplicationAudioEffect(for: app.id)
        let requiresEffects = effect != nil
        // 已进入全局安全静音的 App 即使在两次轮询之间暂停，也保留静音会话，
        // 防止短时间内恢复播放时先漏出声音，下一轮才重新接管。
        let requiresSafetyMute = globalSafetyMuteEnabled
            && (app.isRunningOutput || sessions[app.id] != nil)
        // 音效未知不阻止音量、静音或自定义路由；但只有音效意图的旧会话不能被释放而恢复原声。
        // 这种会话先保留静音 tap 等待修复，用户明确开启基础管理后可在原 tap 上继续处理。
        if applicationEffectsEnabled, !applicationEffectConfigurationAvailable, !state.managed, !requiresRouting,
           let session = sessions[app.id], session.mode == .mixing {
            _ = preserveMixingSession(app.id)
            return
        }
        guard let mode = ApplicationAudioIntent.mode(
            state: state,
            isPlaying: app.isRunningOutput,
            meterVisible: metersVisible,
            requiresRouting: requiresRouting,
            requiresEffects: requiresEffects,
            requiresSafetyMute: requiresSafetyMute
        ) else {
            // 已锁存失败时保留静音中的 mixing tap，等待用户明确重新应用；
            // 只有用户主动关闭管理意图时才真正释放并恢复原声。
            if state.failure != nil, let session = sessions[app.id],
               session.mode == .mixing {
                _ = preserveMixingSession(app.id)
                return
            }
            stop(app.id)
            return
        }
        // 已确认路由是唯一可启动目标；未经确认的旧 UID 绝不能继续重放。
        if mode == .mixing, state.managed, state.boundOutputUID != output.uid {
            guard state.failureReason != .outputChanged else {
                mixStates[app.id] = state
                stop(app.id)
                return
            }
            state.markOutputChanged()
            mixStates[app.id] = state
            diagnosticEventLog.record(category: "applicationFailure",
                                      message: "\(app.id): \(ApplicationMixFailure.outputChanged.message)")
            stop(app.id)
            return
        }
        guard !isFineTuneRunning else {
            mixStates[app.id]?.blockForFineTune()
            stop(app.id)
            return
        }
        guard let group = app.group else { stop(app.id); return }
        let requestedPlaybackRoute: ApplicationPlaybackRoute?
        do {
            requestedPlaybackRoute = try applicationPlaybackRoute(for: output, appID: app.id)
        } catch {
            latchApplicationFailure(error.localizedDescription, for: app.id)
            stop(app.id)
            return
        }
        let expectedPlaybackRoute = requestedPlaybackRoute ?? .single(output)
        if let session = sessions[app.id], session.mode == mode,
           (session.group.objectIDs == group.objectIDs || mode == .mixing) {
            do {
                if session.group.objectIDs != group.objectIDs {
                    try session.suspendForOutputChange()
                    try updateSessionProcesses(session, to: group, applicationID: app.id)
                }
                if mode == .mixing {
                    try applyPlaybackState(session: session, state: state, effect: effect)
                } else {
                    session.setEffect(nil)
                }
                if session.output.uid != output.uid
                    || session.playbackRoute != expectedPlaybackRoute
                    || session.isSuspendedForOutputChange {
                    // 复用同一个 process tap，避免静音来源在旧 tap 销毁与新 tap 建立之间短暂漏声。
                    // 输出 UID 未变时也可能经历过暂停（例如媒体与提示音默认值重新对齐），仍要恢复重放。
                    try session.switchOutput(to: output, playbackRoute: expectedPlaybackRoute)
                }
                try session.checkHealth(expectingAudio: app.isRunningOutput)
                // 完整健康读回表示这次等待已经结束；下一次过渡必须从新的时间起算。
                sessionRouteWaitSince.removeValue(forKey: app.id)
            } catch {
                recordSessionFailure(error, for: app.id)
                // 普通传播等待仍可保留原重放端，但 PCM 已变时必须停掉旧格式并重建。
                // 超时锁存的失败也要当轮暂停，不能再多播放一个轮询周期。
                // mixing 始终保留静音 tap；只读计量可以释放，随后沿同一目标重新创建。
                if let pending = error as? ApplicationRoutePending,
                   pending.reason != .formatChange, mixStates[app.id]?.failure == nil {
                    return
                }
                if session.mode == .mixing {
                    _ = preserveMixingSession(app.id)
                } else {
                    stop(app.id)
                }
            }
        } else {
            // 计量与混音共享所有权检查；必须完整释放旧 tap 后才能改变 muteBehavior。
            guard stop(app.id) else { return }
            start(group, output: output, state: state, mode: mode,
                  playbackRoute: requestedPlaybackRoute, effect: effect)
        }
    }

    /// 同一 tap 扩展进程集合前也要检查其他会话的所有权，不能因复用绕过防重叠校验。
    private func updateSessionProcesses(_ session: any ApplicationAudioSession, to group: AudioProcessGroup,
                                        applicationID: String) throws {
        let others = sessions.filter { $0.key != applicationID }.values.map { $0.group.objectIDs }
        guard !AudioSessionOwnership.overlaps(requested: group.objectIDs, existing: others) else {
            throw AudioFailure("该音频流仍被尚未释放的旧会话持有，请先释放资源再重新应用。")
        }
        try session.updateProcesses(to: group)
    }

    /// 暂停是有意的无声状态：已有混音 tap 不释放，首次启动也不在扬声器建重放端。
    private func holdApplicationForUnavailableRoute(_ app: ApplicationAudioRow,
                                                   output: AudioOutput, state: ApplicationMixState) {
        metering.clear(app.id)
        sessionRouteWaitSince.removeValue(forKey: app.id)
        if let session = sessions[app.id], session.mode == .mixing {
            guard preserveMixingSession(app.id) else { return }
            do {
                if let group = app.group, session.group.objectIDs != group.objectIDs {
                    try updateSessionProcesses(session, to: group, applicationID: app.id)
                }
                try applyPlaybackState(session: session, state: state,
                                       effect: effectiveApplicationAudioEffect(for: app.id))
            } catch { latchApplicationFailure(error.localizedDescription, for: app.id) }
            return
        }
        guard state.failure == nil, let group = app.group, !isFineTuneRunning,
              stop(app.id), let applicationEnvironment else { return }
        guard !AudioSessionOwnership.overlaps(requested: group.objectIDs,
                                              existing: sessions.values.map { $0.group.objectIDs }) else {
            latchApplicationFailure("该音频流仍被尚未释放的旧会话持有，请先释放资源再重新应用。", for: app.id)
            return
        }
        let session = applicationEnvironment.makeSession(group, output, nil, .mixing)
        sessions[app.id] = session
        do {
            try applyPlaybackState(session: session, state: state,
                                   effect: effectiveApplicationAudioEffect(for: app.id))
            try session.startSuspended()
        } catch {
            latchApplicationFailure(error.localizedDescription, for: app.id)
            if session.isReleased { sessions.removeValue(forKey: app.id) }
        }
    }

    func setMeteringVisible(_ visible: Bool, for surface: MeterSurface) {
        metering.setVisible(visible, surface: surface)
        updateMeteringActivity()
    }

    /// 页面出现或切到麦克风页时显式读取一次；后台轮询仍同时受面板可见性约束。
    func setInputControlsVisible(_ visible: Bool, for surface: MeterSurface) {
        let wasNeeded = shouldRefreshInputs
        if visible {
            inputControlsVisibleSurfaces.insert(surface)
        } else {
            inputControlsVisibleSurfaces.remove(surface)
        }
        // 只在刚进入可见麦克风状态时读取一次，关闭页面或重复上报不额外扫描。
        if shouldRefreshInputs, !wasNeeded { refreshInputs() }
    }

    func setApplicationMetersSelected(_ selected: Bool, for surface: MeterSurface) {
        metering.setSelected(selected, surface: surface)
        updateMeteringActivity()
    }

    private func updateMeteringActivity() {
        guard !isShutdown else { return }
        refreshAudioCaptureAccess()
        metering.updateActivity(sessions: sessions) { [weak self] in
            guard let self, !self.isShutdown, !self.isShuttingDown else { return }
            self.metering.refresh(rows: self.playingApplications, sessions: self.sessions)
        }
        reconcileSessions()
    }

    func requestOutput(_ intent: OutputRoutingIntent) {
        guard !isShutdown, !isShuttingDown else { return }
        // 新的设备选择取代先前尚未完成的 APP 恢复操作，不能在另一路由上偷偷清除权限错误。
        pendingApplicationReapplies.removeAll()
        diagnosticEventLog.record(category: "routingRequest",
                                  message: intent.memberUIDs.joined(separator: ", "))
        routing.request(intent, at: routingNow)
        refresh()
    }

    private func rebindManagedApplications(to outputUID: String?) {
        guard let outputUID else { return }
        var nextMixStates = mixStates
        var changed = false
        for key in Array(nextMixStates.keys) {
            guard var state = nextMixStates[key], state.managed else { continue }
            let previous = state
            state.rebind(outputUID: outputUID)
            if state != previous {
                nextMixStates[key] = state
                changed = true
            }
        }
        if changed { mixStates = nextMixStates }
    }

    /// 写入前确认用户看到的麦克风仍是同一个 UID 和句柄；不改用重连后出现的另一设备。
    private func validateInputControlIdentity(_ expected: AudioInput) throws {
        let current = try SystemInput.snapshot()
        guard current.inputs.contains(where: { $0.id == expected.id && $0.uid == expected.uid }) else {
            throw AudioFailure("麦克风身份已变化或已断开，请刷新后重新操作")
        }
        try SystemInput.validateIdentity(expected)
    }

    func selectInput(_ input: AudioInput) {
        let id = input.id
        guard inputAudio?.inputs.contains(where: { $0.id == id && $0.uid == input.uid }) == true else {
            inputOperationError = "所选麦克风已断开，请刷新。"; return
        }
        guard inputAudio?.selectedID != id else { return }
        do { try validateInputControlIdentity(input); try SystemInput.select(input); inputOperationError = nil }
        catch { inputOperationError = error.localizedDescription }
        // 输入选择不调用 stopAll，不主动改变应用输出增益或默认输出。
        refresh()
    }

    func setInputVolume(_ value: Float, on input: AudioInput) {
        let id = input.id
        guard inputAudio?.inputs.contains(where: { $0.id == id && $0.uid == input.uid }) == true else {
            inputOperationError = "所选麦克风已断开，请刷新。"; return
        }
        do { try validateInputControlIdentity(input); try SystemInput.setVolume(value, on: id); inputOperationError = nil }
        catch { inputOperationError = error.localizedDescription }
        refreshInputs()
    }

    func setInputMuted(_ muted: Bool, on input: AudioInput) {
        let id = input.id
        guard inputAudio?.inputs.contains(where: { $0.id == id && $0.uid == input.uid }) == true else {
            inputOperationError = "所选麦克风已断开，请刷新。"; return
        }
        let key = DeviceMuteConfirmationController.Key(direction: .input, id: id)
        deviceMuteConfirmations.cancel(key)
        do {
            try validateInputControlIdentity(input)
            try SystemInput.setMute(muted, on: id)
            inputOperationError = nil
        } catch let pending as AudioDeviceMutePending where pending.deviceID == id && pending.muted == muted {
            inputOperationError = nil
            deviceMuteConfirmations.start(key: key, observe: {
                let snapshot = try SystemInput.snapshot()
                guard snapshot.inputs.contains(where: { $0.id == id && $0.uid == input.uid }) else {
                    throw AudioFailure("麦克风身份已变化或已断开，请刷新后重新操作")
                }
                try SystemInput.validateIdentity(input)
                guard case .available(_, let actual)? = snapshot.controls[id] else {
                    throw AudioFailure("无法读取麦克风静音状态")
                }
                if let error = actual.error { throw AudioFailure(error) }
                return actual.muted == muted
            }, finish: { [weak self] error in
                guard let self, !self.isShutdown, !self.isShuttingDown else { return }
                if let error { self.inputOperationError = error }
                self.refreshInputs()
            })
        } catch { inputOperationError = error.localizedDescription }
        refreshInputs()
    }

    func setApplicationGain(_ value: Float, for id: String) {
        guard applicationRouteConfigurationAvailable else { return }
        guard refreshAudioCaptureAccess() else { return }
        guard var state = mixStates[id] else { return }
        do {
            try state.setGain(value)
            enableIfNeeded(&state)
            mixStates[id] = state
            if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
        } catch { operationError = error.localizedDescription }
    }

    func toggleApplicationMute(_ id: String) {
        guard applicationRouteConfigurationAvailable else { return }
        guard refreshAudioCaptureAccess() else { return }
        guard var state = mixStates[id] else { return }
        state.toggleMute(); enableIfNeeded(&state); mixStates[id] = state
        if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
    }

    /// 全局静音只有明确的开关入口；开启后所有正在处理的 App 都先立即静音，再补齐新会话。
    func setGlobalSafetyMute(_ enabled: Bool) {
        guard enabled != globalSafetyMuteEnabled else { return }
        if enabled {
            guard applicationRouteConfigurationAvailable,
                  audioCaptureAccess.allowsApplicationAudio,
                  !applicationAudioUnavailable else { return }
        }
        globalSafetyMuteEnabled = enabled
        diagnosticEventLog.record(category: "applicationSafetyMute",
                                  message: enabled ? "enabled" : "disabled")
        applyGlobalSafetyMuteToSessions()
        // 开启时让所有当前播放项进入 mixing；关闭时回到各自原有的管理或只读计量状态。
        reconcileSessions()
        updateSafetyMuteRefreshTimer()
    }

    /// 静音控制器只消费会话和意图；路由、会话生命周期和错误仍由模型持有。
    private func applyGlobalSafetyMuteToSessions() {
        safetyMute.apply(enabled: globalSafetyMuteEnabled, sessions: sessions, states: mixStates,
                         keepsMixing: { [self] key, state in
            state.managed || effectiveApplicationAudioEffect(for: key) != nil
                || effectiveApplicationAudioRoute(for: key).isCustom
        }, recordError: { [self] key, message in
            cleanupErrors[key] = message
        })
    }

    private func applyPlaybackState(session: any ApplicationAudioSession,
                                    state: ApplicationMixState,
                                    effect: AppAudioEffectSettings?) throws {
        try safetyMute.applyPlaybackState(session: session, state: state, effect: effect,
                                          enabled: globalSafetyMuteEnabled)
    }

    /// 系统没有同步的新播放通知；短周期只读观察仍受模型生命周期与开关约束。
    private func updateSafetyMuteRefreshTimer() {
        safetyMute.setRefreshActive(monitorsSystem && globalSafetyMuteEnabled && !isShuttingDown && !isShutdown) { [weak self] in
            guard let self, !self.isShutdown, !self.isShuttingDown,
                  self.globalSafetyMuteEnabled else { return }
            self.refreshApplicationState()
        }
    }

    private func enableIfNeeded(_ state: inout ApplicationMixState) {
        // 调整滑杆是明确的管理意图；已锁存的失败不会因为拖动而被偷偷重试。
        guard !state.managed, state.failure == nil else { return }
        guard let output = selectedOutput else { state.fail("当前没有可用系统输出，请恢复后点重新应用。"); return }
        state.enable(outputUID: output.uid)
    }

    func applyApplication(_ id: String) {
        guard applicationRouteConfigurationAvailable else { return }
        guard refreshAudioCaptureAccess() else { return }
        guard !outputRouting.phase.isBusy else {
            if let desired = outputRouting.desired { pendingApplicationReapplies[id] = desired }
            return
        }
        // “重新应用”是明确的恢复意图：外部已切到真实设备时先确认该设备并清理旧组合，
        // 不把 APP 错误清掉后又被失败路由 guard 静默拦住。
        if outputRouting.phase == .failed || outputRouting.confirmed == nil {
            guard let actual = outputRouting.actualOutput, !actual.isAggregate else {
                operationError = "请先选择一台真实输出设备，再重新应用"; return
            }
            let intent = OutputRoutingIntent.single(actual.uid)
            pendingApplicationReapplies[id] = intent
            routing.request(intent, at: routingNow)
            refreshAudio()
        }
        guard let confirmed = outputRouting.confirmed, !outputRouting.phase.isBusy,
              var state = mixStates[id] else { return }
        sessionRouteWaitSince.removeValue(forKey: id)
        if let session = sessions[id], session.mode == .mixing,
           session.isSuspendedForOutputChange {
            // 失败期间保留的 tap 仍在静音来源；重新应用只恢复重放端，不能先 stop 再新建。
            state.enable(outputUID: confirmed.output.uid)
            mixStates[id] = state
            operationError = nil
            if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
            return
        }
        guard stop(id) else { return }
        state.enable(outputUID: confirmed.output.uid)
        mixStates[id] = state
        operationError = nil
        if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
    }

    /// 路由确认后继续完成同一次显式 APP 重试，用户不需要第二次点击。
    private func completePendingApplicationReapplies(on confirmed: ConfirmedOutputRoute) {
        let pending = pendingApplicationReapplies
        pendingApplicationReapplies.removeAll()
        for (id, intent) in pending where intent == confirmed.intent {
            sessionRouteWaitSince.removeValue(forKey: id)
            mixStates[id]?.enable(outputUID: confirmed.output.uid)
        }
    }

    func retryMeter(_ id: String) {
        guard refreshAudioCaptureAccess() else { return }
        pendingApplicationReapplies.removeValue(forKey: id)
        guard mixStates[id]?.managed == false, stop(id) else { return }
        sessionRouteWaitSince.removeValue(forKey: id)
        mixStates[id]?.disable()
        if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
    }

    func stopManaging(_ id: String) {
        pendingApplicationReapplies.removeValue(forKey: id)
        sessionRouteWaitSince.removeValue(forKey: id)
        guard clearApplicationAudioRoute(for: id) else { return }
        mixStates[id]?.disable()
        guard stop(id) else { return }
        if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
    }

    private func start(_ group: AudioProcessGroup, output: AudioOutput,
                       state: ApplicationMixState, mode: ApplicationAudioMode,
                       playbackRoute: ApplicationPlaybackRoute?,
                       effect: AppAudioEffectSettings?) {
        guard !AudioSessionOwnership.overlaps(requested: group.objectIDs, existing: sessions.values.map { $0.group.objectIDs }) else {
            latchApplicationFailure("该音频流仍被尚未释放的旧会话持有，请先释放资源再重新应用。", for: group.id)
            return
        }
        guard !isFineTuneRunning else {
            mixStates[group.id]?.blockForFineTune()
            return
        }
        guard let applicationEnvironment else { return }
        let session = applicationEnvironment.makeSession(group, output, playbackRoute, mode)
        sessions[group.id] = session
        do {
            if mode == .mixing {
                try applyPlaybackState(session: session, state: state, effect: effect)
            } else {
                session.setEffect(nil)
            }
            try session.start()
            sessionRouteWaitSince.removeValue(forKey: group.id)
        } catch {
            recordSessionFailure(error, for: group.id)
            if session.isReleased { sessions.removeValue(forKey: group.id) }
            else if !session.isSuspendedForOutputChange {
                // 启动失败但 tap 已进入静音保活时保留会话；这里只记录真正的清理失败。
                cleanupErrors[group.id] = "\(group.label)：\(error.localizedDescription)"
            }
        }
    }

    private func latchApplicationFailure(_ message: String, for key: String) {
        processReadRecoveries.removeValue(forKey: key)
        pendingApplicationReapplies.removeValue(forKey: key)
        guard mixStates[key]?.failure != message else { return }
        // 只记录本机错误元数据，不记录音频。下次可直接读取确切失败，不再只靠截图中的红点猜测。
        Self.audioLog.error("Application \(key, privacy: .public) processing failed: \(message, privacy: .public)")
        diagnosticEventLog.record(category: "applicationFailure", message: "\(key): \(message)")
        mixStates[key]?.fail(message)
    }

    private func markApplicationOutputChanged(for key: String) {
        guard mixStates[key]?.failureReason != .outputChanged else { return }
        diagnosticEventLog.record(category: "applicationFailure",
                                  message: "\(key): \(ApplicationMixFailure.outputChanged.message)")
        mixStates[key]?.markOutputChanged()
    }

    private func recordSessionFailure(_ error: Error, for key: String) {
        guard let pending = error as? ApplicationRoutePending, let applicationEnvironment else {
            latchApplicationFailure(error.localizedDescription, for: key)
            return
        }
        let now = applicationEnvironment.now()
        if let since = sessionRouteWaitSince[key] {
            if now.timeIntervalSince(since) >= 3 {
                let message = pending.reason == .formatChange
                    ? "应用捕获与输出的音频格式尚未一致，请重新应用"
                    : "应用未在期限内跟随已确认输出，请重新应用"
                latchApplicationFailure(message, for: key)
            }
        } else {
            sessionRouteWaitSince[key] = now
            if let detail = pending.detail {
                Self.audioLog.notice("Application \(key, privacy: .public) waiting for audio: \(detail, privacy: .public)")
            }
        }
    }

    /// Auxmo 聚合只负责捕获来源；重放必须回到它的真实硬件成员，
    /// 不能把公开多输出设备再次嵌套成私有聚合的子设备。
    private func applicationPlaybackRoute(for output: AudioOutput,
                                          appID: String) throws -> ApplicationPlaybackRoute? {
        guard output.isAuxmoMultiOutput else { return nil }
        guard let route = multiOutputRoute,
              route.deviceID == output.id,
              route.uid == output.uid else {
            throw AudioFailure("Auxmo 多设备输出缺少当前成员信息，请重新配置组合")
        }
        let effective = effectiveApplicationAudioRoute(for: appID)
        let playbackOutputs: [AudioOutput]
        switch effective {
        case .custom(let targetUIDs):
            playbackOutputs = route.outputs.filter { targetUIDs.contains($0.uid) }
            guard !playbackOutputs.isEmpty else {
                throw AudioFailure("应用自定义路由的所选设备当前不可用")
            }
        case .allOutputs:
            playbackOutputs = route.outputs
        case .waitingForDevices:
            // 即使未来调用方遗漏等待 guard，这里也绝不能生成全设备重放链。
            throw AudioFailure("所选输出不可用，已暂停播放")
        case .configurationUnavailable:
            throw AppAudioRouteStoreError.readFailed
        }
        return try ApplicationPlaybackRoute(output: output,
                                            playbackOutputs: playbackOutputs,
                                            groupOutputs: route.outputs,
                                            mainOutputUID: route.mainOutputUID)
    }

    private func clearApplicationAudioRoute(for applicationID: String) -> Bool {
        guard applicationRouteConfigurationAvailable else { return false }
        guard let key = applicationRouteStorageKey(for: applicationID),
              appAudioRoutes[key] != nil else { return true }
        var nextRoutes = appAudioRoutes
        nextRoutes.removeValue(forKey: key)
        guard routes.save(nextRoutes) else { return false }
        return true
    }

    /// 只重新读取同一份配置；不删除坏记录、不写入默认值，也不清除其他音频处理错误。
    func reloadApplicationAudioRoutes() {
        processReadRecoveries.removeAll()
        pendingApplicationReapplies.removeAll()
        if !routes.reload() {
            for key in Array(sessions.keys) where cleanupErrors[key] == nil { _ = preserveMixingSession(key) }
        }
        refresh()
    }

    @discardableResult
    func stop(_ key: String) -> Bool {
        processReadRecoveries.removeValue(forKey: key)
        guard let session = sessions[key] else { return true }
        do {
            try session.stop(); sessions.removeValue(forKey: key); cleanupErrors.removeValue(forKey: key)
            metering.clear(key, ended: true)
            return true
        } catch {
            cleanupErrors[key] = "\(session.group.label)：\(error.localizedDescription)"
            latchApplicationFailure("音频资源未能释放，请点击重试释放。", for: key)
            return false
        }
    }
    @discardableResult
    func stopAll() -> Bool {
        for key in Array(sessions.keys) { stop(key) }
        return sessions.isEmpty
    }

    func shutdown() -> Bool {
        shutdownStep() == .complete
    }

    func cancelShutdown() {
        guard !isShutdown else { return }
        lifecycle = .running
        shutdownRouteRequested = false
        shutdownSweepCompleted = false
        diagnosticEventLog.record(category: "lifecycle", message: "shutdown cancelled")
        // 保留未释放的会话和真实错误，恢复只读观察，不自动清错或重建失败的处理链。
        refresh()
    }

    /// 退出期间只推进释放，不走 refreshAudio 的重绑定和会话恢复路径。
    func shutdownStep() -> ApplicationShutdownResult {
        if isShutdown { return .complete }
        lifecycle = .stopping
        routing.discardQueuedRequestForShutdown()
        pendingApplicationReapplies.removeAll()
        processReadRecoveries.removeAll()
        guard stopAll() else {
            return .failed(cleanupErrors.keys.sorted().compactMap { cleanupErrors[$0] }.joined(separator: "；"))
        }
        do {
            try audioEngine.shutdown()
        } catch {
            return .failed(error.localizedDescription)
        }
        if !shutdownSweepCompleted {
            shutdownSweepCompleted = true
            do {
                // 退出前重新枚举一次，清理尚未进入 pendingCleanup 的孤儿聚合。
                routing.observe(try outputHardware.snapshot(), at: routingNow)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        if routing.retainedRoute != nil || !outputRouting.pendingCleanup.isEmpty || outputRouting.phase.isBusy {
            if !shutdownRouteRequested, !outputRouting.phase.isBusy {
                shutdownRouteRequested = true
                routing.stop(at: routingNow)
            }
            do { routing.observe(try outputHardware.snapshot(), at: routingNow) }
            catch { return .failed(error.localizedDescription) }
            if outputRouting.phase == .failed {
                return .failed(outputRouting.error ?? "音频组合未能释放。")
            }
            if outputRouting.phase.isBusy { return .waiting }
            // 退出开始前已有切换在进行，必须等它结束后再发出唯一一次退出释放请求。
            if routing.retainedRoute != nil || !outputRouting.pendingCleanup.isEmpty { return .waiting }
        }
        routeConfirmationTimer?.invalidate(); routeConfirmationTimer = nil
        listeningStatistics.persist()
        lifecycle = .stopped; headphones.shutdown()
        timer?.invalidate(); timer = nil
        safetyMute.stopRefresh()
        deviceMuteConfirmations.cancelAll()
        metering.shutdown()
        removeOutputRouteListener()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        diagnosticEventLog.record(category: "lifecycle", message: "shutdown completed")
        return .complete
    }
}
