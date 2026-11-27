import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Auxmo 0.5 核心实时音频图执行引擎。
/// 每个应用是一个独立的 `AudioAppSource` 捕获与 DSP 节点链，每台物理输出设备共享唯一的 `AudioDeviceSink` 混音总线。
@MainActor
public final class AuxmoAudioEngine {
    private let sourceHardware: AudioSourceHardware
    private let sinkHardware: AudioSinkHardware
    public let excludedPID: Int32
    private let ringCapacityFrames: Int

    private var physicalOutputs: [String: AudioOutput] = [:]
    private var sinks: [String: AudioDeviceSink] = [:]
    private var activeSources: [ObjectIdentifier: EngineApplicationSession] = [:]
    public private(set) var latestPlan: AudioGraphPlan = .empty

    public init(sourceHardware: AudioSourceHardware,
                sinkHardware: AudioSinkHardware,
                excludedPID: Int32 = getpid(),
                ringCapacityFrames: Int = 16_384) {
        self.sourceHardware = sourceHardware
        self.sinkHardware = sinkHardware
        self.excludedPID = excludedPID
        self.ringCapacityFrames = ringCapacityFrames
    }

    /// 真实运行时入口在主 actor 内取得两类 HAL 适配器，测试入口继续显式注入适配器。
    public convenience init(excludedPID: Int32 = getpid(),
                            ringCapacityFrames: Int = 16_384) {
        self.init(sourceHardware: .live,
                  sinkHardware: .live,
                  excludedPID: excludedPID,
                  ringCapacityFrames: ringCapacityFrames)
    }

    /// 同步当前系统已枚举的真实硬件输出表，并回收已完成淡出且无活跃输入边的空闲物理 Sink。
    public func updatePhysicalOutputs(_ outputs: [AudioOutput]) {
        var map: [String: AudioOutput] = [:]
        for output in outputs where !output.isAggregate {
            map[output.uid] = output
        }
        physicalOutputs = map
        _ = try? releaseIdleSinks()
    }

    @discardableResult
    public func compilePlan(_ world: AudioEngineWorld) -> AudioGraphPlan {
        var adjusted = world
        adjusted.excludedPID = excludedPID
        let plan = AudioGraphPlanner.compile(adjusted)
        latestPlan = plan
        return plan
    }

    public func makeSession(group: AudioProcessGroup,
                            output: AudioOutput,
                            playbackRoute: ApplicationPlaybackRoute? = nil,
                            mode: ApplicationAudioMode = .mixing) -> EngineApplicationSession {
        let session = EngineApplicationSession(
            engine: self,
            group: group,
            output: output,
            playbackRoute: playbackRoute,
            mode: mode,
            sourceHardware: sourceHardware,
            excludedPID: excludedPID,
            ringCapacityFrames: ringCapacityFrames
        )
        activeSources[ObjectIdentifier(session)] = session
        return session
    }

    fileprivate func unregisterSession(_ session: EngineApplicationSession) {
        activeSources.removeValue(forKey: ObjectIdentifier(session))
    }

    public var activeSinkUIDs: [String] {
        sinks.values.filter(\.isRunning).map(\.output.uid).sorted()
    }

    public func sink(for uid: String) -> AudioDeviceSink? {
        sinks[uid]
    }

    public var diagnosticSnapshot: AudioEngineDiagnosticSnapshot {
        for sink in sinks.values { sink.reclaimRetiredSlots() }
        let sinkSnapshots = sinks.keys.sorted().compactMap { sinks[$0]?.snapshot }
        let edgeCount = sinkSnapshots.reduce(0) { $0 + $1.activeSourceIDs.count }
        let sortedExplanations = latestPlan.explanations.keys.sorted().compactMap { latestPlan.explanations[$0] }
        return AudioEngineDiagnosticSnapshot(
            activeSourceCount: activeSources.values.filter { !$0.isReleased }.count,
            activeSinkCount: sinkSnapshots.filter { $0.stage == .running }.count,
            activeEdgeCount: edgeCount,
            sinks: sinkSnapshots,
            explanations: sortedExplanations
        )
    }

    /// 将 Source 的环形缓冲连接至目标物理 Sink 集合，并对移除的旧 Sink 执行 20ms 平滑淡出解绑。
    fileprivate func updateSourceEdges(sourceKey: String,
                                       ring: AudioBroadcastRingBuffer,
                                       previousSinkUIDs: Set<String>,
                                       nextSinkUIDs: [String],
                                       fallbackOutput: AudioOutput) throws {
        let nextSet = Set(nextSinkUIDs)
        // 先标记不再需要的旧边进行平滑淡出。
        for removedUID in previousSinkUIDs.subtracting(nextSet) {
            sinks[removedUID]?.detachSource(id: sourceKey)
        }

        var attachedNow: [String] = []
        do {
            for uid in nextSinkUIDs {
                let targetOutput = try resolvePhysicalOutput(uid: uid, fallback: fallbackOutput)
                let sink: AudioDeviceSink
                if let existing = sinks[uid] {
                    sink = existing
                } else {
                    let created = AudioDeviceSink(output: targetOutput, hardware: sinkHardware)
                    sinks[uid] = created
                    sink = created
                }
                try sink.startIfNeeded(updatedOutput: targetOutput)
                try sink.attachSource(id: sourceKey, ring: ring)
                attachedNow.append(uid)
            }
        } catch {
            for uid in attachedNow where !previousSinkUIDs.contains(uid) {
                sinks[uid]?.detachSource(id: sourceKey)
            }
            _ = try? releaseIdleSinks()
            throw error
        }

        _ = try? releaseIdleSinks()
    }

    fileprivate func detachAllEdges(sourceKey: String, sinkUIDs: Set<String>) {
        for uid in sinkUIDs {
            sinks[uid]?.detachSource(id: sourceKey)
        }
        _ = try? releaseIdleSinks()
    }

    fileprivate func validateSinkTargets(route: ApplicationPlaybackRoute, fallbackOutput: AudioOutput) throws {
        for uid in route.playbackDeviceUIDs {
            let output = try resolvePhysicalOutput(uid: uid, fallback: fallbackOutput)
            try sinkHardware.validateOutput(output)
        }
    }

    fileprivate func checkSinkHealth(sinkUIDs: Set<String>) throws {
        for uid in sinkUIDs {
            guard let sink = sinks[uid] else {
                throw AudioFailure("目标物理输出未就绪，正在重试连接")
            }
            try sink.checkHealth()
        }
        _ = try? releaseIdleSinks()
    }

    private func resolvePhysicalOutput(uid: String, fallback: AudioOutput) throws -> AudioOutput {
        if let known = physicalOutputs[uid] { return known }
        if !fallback.isAggregate, fallback.uid == uid { return fallback }
        throw AudioFailure("找不到目标物理输出设备：\(uid)")
    }

    /// 停止所有已无活跃或淡出输入边的物理输出 Sink。
    @discardableResult
    public func releaseIdleSinks() throws -> Bool {
        var failures: [Error] = []
        for (uid, sink) in Array(sinks) {
            sink.reclaimRetiredSlots()
            guard !sink.hasActiveOrFadingSources else { continue }
            do {
                try sink.stop()
                sinks.removeValue(forKey: uid)
            } catch {
                failures.append(error)
            }
        }
        if !failures.isEmpty {
            throw AudioResourceFailures(failures, operation: "释放空闲物理输出")
        }
        return true
    }

    /// 引擎退出时完整释放全部 Source 与全部共享物理 Sink。
    public func shutdown() throws {
        var failures: [Error] = []
        for session in Array(activeSources.values) where !session.isReleased {
            do { try session.stop() }
            catch { failures.append(error) }
        }
        for (uid, sink) in Array(sinks) {
            do {
                try sink.stop()
                sinks.removeValue(forKey: uid)
            } catch {
                failures.append(error)
            }
        }
        if !failures.isEmpty {
            throw AudioResourceFailures(failures, operation: "关闭音频引擎")
        }
    }
}

/// 绑定到 `AuxmoAudioEngine` 的单应用音频会话适配器：底层复用共享物理 `AudioDeviceSink` 与独立 `AudioAppSource`。
@MainActor
public final class EngineApplicationSession: ApplicationAudioSession {
    private unowned let engine: AuxmoAudioEngine
    private let sessionToken = UUID().uuidString
    public private(set) var group: AudioProcessGroup
    public private(set) var output: AudioOutput
    public let mode: ApplicationAudioMode
    public private(set) var gain: Float = 1
    public private(set) var muted = false
    private var effectSettings: AppAudioEffectSettings?
    private let sourceHardware: AudioSourceHardware
    public let source: AudioAppSource
    private var connectedSinkUIDs: Set<String> = []
    private var activityWatchdog = AudioActivityWatchdog()
    public private(set) var playbackRoute: ApplicationPlaybackRoute

    public var isActive: Bool {
        guard source.isCapturing else { return false }
        if mode == .mixing { return !connectedSinkUIDs.isEmpty }
        return true
    }

    public var isReleased: Bool {
        source.isReleased && connectedSinkUIDs.isEmpty
    }

    public var isSuspendedForOutputChange: Bool {
        source.isSuspended && connectedSinkUIDs.isEmpty
    }

    /// Source 使用与物理输出无关的进程混音 Tap，设备切换只需交叉切换 Sink 边。
    public let supportsContinuousOutputSwitch = true

    public var resourceSnapshot: AudioSessionResourceSnapshot {
        source.snapshot
    }

    init(engine: AuxmoAudioEngine,
         group: AudioProcessGroup,
         output: AudioOutput,
         playbackRoute: ApplicationPlaybackRoute?,
         mode: ApplicationAudioMode,
         sourceHardware: AudioSourceHardware,
         excludedPID: Int32,
         ringCapacityFrames: Int) {
        self.engine = engine
        self.group = group
        self.output = output
        self.playbackRoute = playbackRoute ?? .single(output)
        self.mode = mode
        self.sourceHardware = sourceHardware
        self.source = AudioAppSource(
            hardware: sourceHardware,
            excludedPID: excludedPID,
            ringCapacityFrames: ringCapacityFrames
        )
    }

    public func consumePeak() -> Float? {
        guard isActive,
              let state = source.renderState,
              state.captureEnabled.load(ordering: .acquiring),
              !state.fault.load(ordering: .relaxed),
              state.callbacks.load(ordering: .relaxed) > 0 else {
            return nil
        }
        return state.peak.consume()
    }

    public func startSuspended() throws {
        guard mode == .mixing, !group.objectIDs.isEmpty else {
            throw AudioFailure("只有具有已注册进程的混音会话才能等待所选输出")
        }
        guard isReleased else { throw AudioFailure("该应用已接管，不能重复启动") }
        let description = try AudioAppSource.makeTapDescription(
            group: group,
            tapDeviceUID: "",
            mode: mode,
            suspended: true,
            excludedPID: engine.excludedPID
        )
        try source.createTap(description)
    }

    public func updateProcesses(to group: AudioProcessGroup) throws {
        guard let current = source.description,
              group.id == self.group.id,
              group.bundleID == self.group.bundleID,
              !group.objectIDs.isEmpty else {
            throw AudioFailure("应用静音捕获的进程身份无效，未改变会话")
        }
        let description = try AudioAppSource.makeTapDescription(
            group: group,
            tapDeviceUID: "",
            mode: mode,
            suspended: current.deviceUID == nil,
            excludedPID: engine.excludedPID
        )
        description.uuid = current.uuid
        try source.updateTap(description)
        self.group = group
    }

    public func start() throws {
        let interval = AudioSwitchTrace.begin("StartEngineSession")
        defer { AudioSwitchTrace.end("StartEngineSession", interval) }
        guard !group.objectIDs.isEmpty else { throw AudioFailure("应用尚未创建音频流") }
        guard isReleased else { throw AudioFailure("该应用已接管，不能重复启动") }
        try validateOutputRoute(output, playbackRoute: playbackRoute)
        do {
            try validateRoutes(playbackRoute)
            let description = try AudioAppSource.makeTapDescription(
                group: group,
                tapDeviceUID: "",
                mode: mode,
                suspended: false,
                excludedPID: engine.excludedPID
            )
            try source.createTap(description)
            try source.startCapture(mode: mode, gain: muted ? 0 : gain, effect: effectSettings)
            if mode == .mixing {
                try engine.updateSourceEdges(
                    sourceKey: sessionToken,
                    ring: source.ringBuffer,
                    previousSinkUIDs: [],
                    nextSinkUIDs: playbackRoute.playbackDeviceUIDs,
                    fallbackOutput: output
                )
                connectedSinkUIDs = Set(playbackRoute.playbackDeviceUIDs)
            }
            activityWatchdog = AudioActivityWatchdog()
        } catch {
            if mode == .mixing, source.hasTap {
                do { try suspendForOutputChange() }
                catch let cleanupError {
                    throw AudioResourceFailures([error, cleanupError], operation: "启动应用音频")
                }
            } else {
                do { try stop() }
                catch let cleanupError {
                    throw AudioResourceFailures([error, cleanupError], operation: "启动应用音频")
                }
            }
            throw error
        }
    }

    public func suspendForOutputChange() throws {
        let interval = AudioSwitchTrace.begin("SuspendEngineSession")
        defer { AudioSwitchTrace.end("SuspendEngineSession", interval) }
        guard mode == .mixing, let current = source.description else {
            throw AudioFailure("应用音频会话尚未启动，不能暂停输出路由")
        }
        let description = try AudioAppSource.makeTapDescription(
            group: group,
            tapDeviceUID: playbackRoute.tapDeviceUID,
            mode: mode,
            suspended: true,
            excludedPID: engine.excludedPID
        )
        description.uuid = current.uuid
        source.silenceCapture()
        engine.detachAllEdges(sourceKey: sessionToken, sinkUIDs: connectedSinkUIDs)
        connectedSinkUIDs.removeAll()

        var failures: [AudioFailure] = []
        do { try source.updateTap(description) }
        catch { failures.append(HAL.operationFailure(error, operation: "更新应用静音捕获")) }
        do { try source.stopCapture() }
        catch { failures.append(HAL.operationFailure(error, operation: "暂停应用捕获")) }
        if !failures.isEmpty { throw AudioResourceFailures(failures: failures) }
    }

    public func switchOutput(to output: AudioOutput, playbackRoute: ApplicationPlaybackRoute) throws {
        let interval = AudioSwitchTrace.begin("SwitchEngineOutput")
        defer { AudioSwitchTrace.end("SwitchEngineOutput", interval) }
        guard let currentDescription = source.description,
              (isActive || isSuspendedForOutputChange) else {
            throw AudioFailure("应用音频会话尚未启动，不能切换输出")
        }
        try validateOutputRoute(output, playbackRoute: playbackRoute)
        do {
            try validateRoutes(playbackRoute)

            // 热路径：进程混音 Tap 与物理输出解耦，仅在共享物理 Sink 总线上做 20ms 交叉淡入淡出重连。
            // 切换输出时不停止捕获回调，避免新捕获聚合预热期间产生空档。
            if source.isCapturing,
               let activeFormat = source.activeFormat,
               let captureID = source.captureDeviceID,
               (try? ProcessAudioSession.requireMatchingPCM(
                   captured: activeFormat,
                   current: sourceHardware.captureFormat(captureID)
               )) != nil {
                if mode == .mixing {
                    source.ringBuffer.setActive(true)
                    try engine.updateSourceEdges(
                        sourceKey: sessionToken,
                        ring: source.ringBuffer,
                        previousSinkUIDs: connectedSinkUIDs,
                        nextSinkUIDs: playbackRoute.playbackDeviceUIDs,
                        fallbackOutput: output
                    )
                    connectedSinkUIDs = Set(playbackRoute.playbackDeviceUIDs)
                }
                self.output = output
                self.playbackRoute = playbackRoute
                return
            }

            // 只有捕获格式真实变化时才重建捕获流；设备目标变化本身由上面的 Sink 交叉切换处理。
            engine.detachAllEdges(sourceKey: sessionToken, sinkUIDs: connectedSinkUIDs)
            connectedSinkUIDs.removeAll()
            try source.stopCapture()

            let nextDescription = try AudioAppSource.makeTapDescription(
                group: group,
                tapDeviceUID: "",
                mode: mode,
                suspended: false,
                excludedPID: engine.excludedPID
            )
            nextDescription.uuid = currentDescription.uuid
            try source.updateTap(nextDescription)
            try source.startCapture(mode: mode, gain: muted ? 0 : gain, effect: effectSettings)
            if mode == .mixing {
                try engine.updateSourceEdges(
                    sourceKey: sessionToken,
                    ring: source.ringBuffer,
                    previousSinkUIDs: [],
                    nextSinkUIDs: playbackRoute.playbackDeviceUIDs,
                    fallbackOutput: output
                )
                connectedSinkUIDs = Set(playbackRoute.playbackDeviceUIDs)
            }
            activityWatchdog = AudioActivityWatchdog()
            self.output = output
            self.playbackRoute = playbackRoute
        } catch {
            do { try suspendForOutputChange() }
            catch let cleanupError {
                throw AudioResourceFailures([error, cleanupError], operation: "切换应用输出")
            }
            throw error
        }
    }

    public func setGain(_ value: Float) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw AudioFailure("应用增益必须在 0～100% 之间")
        }
        gain = value
        publishGain()
    }

    public func setMuted(_ value: Bool) {
        muted = value
        publishGain()
    }

    public func setSafetyMute(_ value: Bool) throws {
        guard mode == .metering, let current = source.description else { return }
        let description = try AudioAppSource.makeTapDescription(
            group: group,
            tapDeviceUID: playbackRoute.tapDeviceUID,
            mode: mode,
            suspended: current.deviceUID == nil,
            excludedPID: engine.excludedPID
        )
        description.uuid = current.uuid
        description.muteBehavior = value ? .muted : .unmuted
        do {
            try source.updateTap(description)
        } catch {
            throw HAL.operationFailure(error, operation: "更新全局安全静音")
        }
    }

    private func publishGain() {
        source.renderState?.target.store((muted ? Float(0) : gain).bitPattern, ordering: .relaxed)
    }

    public func setEffect(_ settings: AppAudioEffectSettings?) {
        effectSettings = mode == .mixing ? settings : nil
        source.renderState?.setEffect(effectSettings)
    }

    public func checkHealth(expectingAudio: Bool = true) throws {
        guard isActive,
              source.renderState?.captureEnabled.load(ordering: .acquiring) == true,
              let captureID = source.captureDeviceID else {
            throw AudioFailure("音频接管未成功启动，正在重试释放残留资源")
        }
        try validateRoutes(playbackRoute)
        let actualCapture = try sourceHardware.captureFormat(captureID)
        guard let activeFormat = source.activeFormat else {
            throw AudioFailure("音频会话缺少已确认的捕获格式")
        }
        try ProcessAudioSession.requireMatchingPCM(captured: activeFormat, current: actualCapture)
        if source.renderState?.fault.load(ordering: .relaxed) == true {
            throw AudioFailure("实时捕获缓冲布局不匹配，已请求停止接管")
        }
        if mode == .mixing {
            try engine.checkSinkHealth(sinkUIDs: connectedSinkUIDs)
        }
        if let state = source.renderState,
           activityWatchdog.isStalled(expectingAudio: expectingAudio,
                                      callbacks: state.callbacks.load(ordering: .relaxed),
                                      at: Date()) {
            throw AudioFailure("未收到音频回调，请检查录制授权和应用播放状态")
        }
    }

    public func stop() throws {
        let interval = AudioSwitchTrace.begin("StopEngineSession")
        defer { AudioSwitchTrace.end("StopEngineSession", interval) }
        engine.detachAllEdges(sourceKey: sessionToken, sinkUIDs: connectedSinkUIDs)
        connectedSinkUIDs.removeAll()
        try source.stop()
        effectSettings = nil
        engine.unregisterSession(self)
    }

    private func validateOutputRoute(_ output: AudioOutput, playbackRoute: ApplicationPlaybackRoute) throws {
        guard !output.isAggregate || output.isAuxmoMultiOutput else {
            throw AudioFailure("第三方聚合输出暂不支持 APP 独立音量或实时电平")
        }
        let targets = playbackRoute.playbackDeviceUIDs
        guard !targets.isEmpty, Set(targets).count == targets.count else {
            throw AudioFailure("应用音频路由缺少有效输出目标")
        }
        if mode == .mixing {
            try engine.validateSinkTargets(route: playbackRoute, fallbackOutput: output)
        } else if !output.isAuxmoMultiOutput {
            try engine.validateSinkTargets(route: .single(output), fallbackOutput: output)
        }
    }

    private func validateRoutes(_ route: ApplicationPlaybackRoute) throws {
        let routes = try sourceHardware.processRoutes(group)
        guard route.acceptsActiveProcessRoutes(routes) else {
            let actual = routes.filter(\.isRunningOutput).flatMap(\.deviceUIDs).joined(separator: ",")
            throw ApplicationRoutePending(detail: "expected=\(route.sourceOutputUID); actual=\(actual)")
        }
    }
}
