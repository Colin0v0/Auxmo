import CoreAudio
import AudioToolbox
import Foundation
import Synchronization

/// 每个声道共用同一个逐帧增益，避免左右声道的淡入进度不同。
public struct GainRamp {
    public private(set) var current: Float = 1
    public let step: Float
    public init(sampleRate: Double, initial: Float = 1) {
        current = initial
        step = Float(1 / (sampleRate * 0.02))
    }
    public mutating func advance(toward target: Float) -> Float {
        if current < target { current = min(target, current + step) }
        if current > target { current = max(target, current - step) }
        return current
    }
}

// 此对象在启动前分配，在 I/O 停止并销毁回调之后才释放。
// 回调不做 HAL 查询、日志、集合构造、锁等待或界面操作。
final class RenderState {
    /// 生命周期停止信号独立于用户增益；即使 HAL 停止失败，下一次回调也只输出已清零的缓冲。
    let outputEnabled = Atomic<Bool>(true)
    let target = Atomic<UInt32>(Float(1).bitPattern)
    let effectWord = Atomic<UInt64>(AppAudioEffectParameterWord.pack(.disabled))
    let spatialWord = Atomic<UInt64>(AppAudioSpatialParameterWord.pack(.disabled))
    let dynamicsWord = Atomic<UInt64>(AppAudioDynamicsParameterWord.pack(.disabled))
    let fault = Atomic<Bool>(false)
    let callbacks = Atomic<UInt64>(0)
    let peak = AudioPeakMailbox()
    let mode: ApplicationAudioMode
    var ramp: GainRamp
    /// 末端淡出覆盖 EQ 与混响存量，不能只把送入音效的新声音归零。
    var silenceRamp: GainRamp
    var effects: AppAudioEffectDSP
    init(sampleRate: Double, initialGain: Float = 1, mode: ApplicationAudioMode = .mixing,
         effect: AppAudioEffectSettings? = nil) {
        self.mode = mode
        ramp = GainRamp(sampleRate: sampleRate, initial: initialGain)
        silenceRamp = GainRamp(sampleRate: sampleRate, initial: initialGain == 0 ? 0 : 1)
        effects = AppAudioEffectDSP(sampleRate: sampleRate)
        effectWord.store(AppAudioEffectParameterWord.pack(effect), ordering: .relaxed)
        spatialWord.store(AppAudioSpatialParameterWord.pack(effect), ordering: .relaxed)
        dynamicsWord.store(AppAudioDynamicsParameterWord.pack(effect), ordering: .relaxed)
    }

    /// 原子参数只保存用户意图；滤波器状态和系数表继续由已启动的音频会话独占。
    func setEffect(_ settings: AppAudioEffectSettings?) {
        effectWord.store(AppAudioEffectParameterWord.pack(settings), ordering: .relaxed)
        spatialWord.store(AppAudioSpatialParameterWord.pack(settings), ordering: .relaxed)
        dynamicsWord.store(AppAudioDynamicsParameterWord.pack(settings), ordering: .relaxed)
    }
}

/// Process Tap 的来源设备与真正承载重放音频的设备必须分开建模。
/// Auxmo 多设备聚合本身不能再作为子设备嵌套，因此重放端直接使用它的真实成员构建私有镜像聚合。
public struct ApplicationPlaybackRoute: Equatable, Sendable {
    /// 进程在 HAL 中声明的公开输出设备；多设备时通常就是 Auxmo 聚合。
    public let sourceOutputUID: String
    public let tapDeviceUID: String
    public let playbackDeviceUIDs: [String]
    public let mainDeviceUID: String
    public let isStacked: Bool
    /// 进程仍可能报告聚合内其他成员，即使本次只重放到其中一个子集。
    public let acceptedProcessRouteUIDs: Set<String>

    /// 单设备不经过聚合镜像，直接捕获并重放到同一台真实硬件。
    public init(single output: AudioOutput) {
        sourceOutputUID = output.uid
        tapDeviceUID = output.uid
        playbackDeviceUIDs = [output.uid]
        mainDeviceUID = output.uid
        isStacked = false
        acceptedProcessRouteUIDs = [output.uid]
    }

    /// 多设备从聚合的主成员捕获，再用用户选择的真实成员子集建立私有输出。
    /// Process Tap 直接绑定公开聚合设备时能启动，但回调输入会一直为空；
    /// 因此捕获源必须是真实硬件成员，公开聚合只用于确认进程当前输出路由。
    public init(output: AudioOutput, playbackOutputs: [AudioOutput],
                groupOutputs: [AudioOutput]? = nil,
                mainOutputUID: String) throws {
        guard output.isAuxmoMultiOutput else {
            throw AudioFailure("只有 Auxmo 多设备输出可以使用成员镜像混音")
        }
        let groupOutputs = groupOutputs ?? playbackOutputs
        guard !playbackOutputs.isEmpty,
              !groupOutputs.isEmpty,
              playbackOutputs.allSatisfy(\.supportsSimultaneousOutput) else {
            throw AudioFailure("多设备输出的成员不完整，无法启动 APP 独立音量")
        }
        let uids = playbackOutputs.map(\.uid)
        guard Set(uids).count == uids.count else {
            throw AudioFailure("多设备输出包含重复成员，无法启动 APP 独立音量")
        }
        let groupUIDs = groupOutputs.map(\.uid)
        guard Set(groupUIDs).count == groupUIDs.count,
              Set(uids).isSubset(of: Set(groupUIDs)),
              groupUIDs.contains(mainOutputUID) else {
            throw AudioFailure("应用路由目标不在当前多设备输出组中")
        }
        sourceOutputUID = output.uid
        tapDeviceUID = mainOutputUID
        playbackDeviceUIDs = uids
        // 私有输出聚合以第一个实际重放成员为主时钟；自定义子集可以不包含公开组主成员。
        mainDeviceUID = uids.contains(mainOutputUID) ? mainOutputUID : uids[0]
        // 单目标保持非堆叠，和多设备组内普通单设备输出语义一致。
        isStacked = uids.count > 1
        acceptedProcessRouteUIDs = Set(groupUIDs).union([output.uid])
    }

    public static func single(_ output: AudioOutput) -> Self {
        Self(single: output)
    }

    /// 独立物理设备路由：捕获应用在系统输出上的流（或全进程立体声流），分发至任意在线真实硬件集合。
    public init(independentSource: AudioOutput?, playbackOutputs: [AudioOutput]) throws {
        guard !playbackOutputs.isEmpty,
              playbackOutputs.allSatisfy(\.supportsSimultaneousOutput) else {
            throw AudioFailure("独立设备路由缺少可用的真实输出硬件")
        }
        let uids = playbackOutputs.map(\.uid)
        guard Set(uids).count == uids.count else {
            throw AudioFailure("独立设备路由包含重复的输出设备")
        }
        let sourceUID = independentSource?.uid ?? ""
        sourceOutputUID = sourceUID
        tapDeviceUID = independentSource?.isAggregate == true ? "" : sourceUID
        playbackDeviceUIDs = uids
        let preferredMain = playbackOutputs.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
            ?? playbackOutputs.first { !$0.isBluetooth }
            ?? playbackOutputs[0]
        mainDeviceUID = preferredMain.uid
        isStacked = uids.count > 1
        var accepted = Set(uids)
        if !sourceUID.isEmpty { accepted.insert(sourceUID) }
        acceptedProcessRouteUIDs = accepted
    }

    /// HAL 对“播放到 Auxmo 多设备输出”的进程可能报告公开聚合 UID，
    /// 也可能报告聚合中的真实成员 UID；这两类都属于当前已确认的播放路由。
    public func acceptsProcessRouteUIDs(_ routeUIDs: [String]) -> Bool {
        guard !routeUIDs.isEmpty else { return false }
        return routeUIDs.allSatisfy { acceptedProcessRouteUIDs.contains($0) }
    }

    /// 只校验当前确实在输出的进程对象。一个 App 可能同时注册主进程、
    /// 音频 helper 和视频 helper；空闲 helper 的旧路由不能阻断正在播放的对象。
    func acceptsActiveProcessRoutes(_ routes: [ProcessOutputRoute]) -> Bool {
        let activeRoutes = routes.filter(\.isRunningOutput)
        guard !activeRoutes.isEmpty else { return true }
        return activeRoutes.allSatisfy {
            // HAL 可报告“正在播放”但尚未提供设备列表；这不是已观测到路由冲突。
            // 不从空列表推断默认设备：实际捕获仍由 tapDeviceUID 严格限定到用户选定的流。
            // 只拒绝明确列出的其他输出，避免 Chrome 的空元数据把捕获永久挡在启动前。
            $0.deviceUIDs.isEmpty || acceptsProcessRouteUIDs($0.deviceUIDs)
        }
    }

    public func aggregateDescription(tapUUID: UUID, aggregateUID: String) -> [String: Any] {
        return [
            kAudioAggregateDeviceNameKey: "Auxmo Application Output",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: NSNumber(value: true),
            kAudioAggregateDeviceIsStackedKey: NSNumber(value: isStacked),
            kAudioAggregateDeviceMainSubDeviceKey: mainDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: playbackDeviceUIDs.map { uid in
                [
                    kAudioSubDeviceUIDKey: uid,
                    kAudioSubDeviceDriftCompensationKey: NSNumber(value: uid == mainDeviceUID ? 0 : 1)
                ] as [String: Any]
            },
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: NSNumber(value: true)
            ]]
        ]
    }
}

/// HAL 进程对象的一次输出路由快照。
public struct ProcessOutputRoute: Equatable, Sendable {
    public let isRunningOutput: Bool
    public let deviceUIDs: [String]

    public init(isRunningOutput: Bool, deviceUIDs: [String]) {
        self.isRunningOutput = isRunningOutput
        self.deviceUIDs = deviceUIDs
    }
}

let auxmoAudioCallback: AudioDeviceIOProc = { _, _, input, _, output, _, context in
    let outs = UnsafeMutableAudioBufferListPointer(output)
    // 每次先清空输出，任何不支持的布局都不会把未初始化内存送到扬声器。
    for buffer in outs {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    guard let context else { return noErr }
    let state = Unmanaged<RenderState>.fromOpaque(context).takeUnretainedValue()
    guard state.outputEnabled.load(ordering: .acquiring) else { return noErr }
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard !ins.isEmpty, ins.count == outs.count else { state.fault.store(true, ordering: .relaxed); return noErr }
    var frames: Int?
    var totalChannels = 0
    for i in ins.indices {
        let source = ins[i], destination = outs[i]
        guard source.mNumberChannels > 0, source.mNumberChannels == destination.mNumberChannels,
              source.mDataByteSize == destination.mDataByteSize,
              source.mDataByteSize % (4 * source.mNumberChannels) == 0 else {
            state.fault.store(true, ordering: .relaxed); return noErr
        }
        let count = Int(source.mDataByteSize / (4 * source.mNumberChannels))
        if let frames, frames != count { state.fault.store(true, ordering: .relaxed); return noErr }
        frames = count
        totalChannels += Int(source.mNumberChannels)
        // HAL 可用空指针表示尚未有输入；保持本次静音，不虚构音频样本。
        guard source.mData != nil, destination.mData != nil else { return noErr }
    }
    guard let frames, (1...2).contains(totalChannels) else {
        state.fault.store(true, ordering: .relaxed)
        return noErr
    }
    let target = Float(bitPattern: state.target.load(ordering: .relaxed))
    // 计量模式只读取原声峰值；音效参数只有在真实重放时才进入湿声路径。
    let effectWord = state.mode == .mixing
        ? state.effectWord.load(ordering: .relaxed)
        : AppAudioEffectParameterWord.pack(.disabled)
    let spatialWord = state.mode == .mixing
        ? state.spatialWord.load(ordering: .relaxed)
        : AppAudioSpatialParameterWord.pack(.disabled)
    state.effects.beginBuffer(effectWord: effectWord, spatialWord: spatialWord,
                              dynamicsWord: state.mode == .mixing
                                  ? state.dynamicsWord.load(ordering: .relaxed)
                                  : AppAudioDynamicsParameterWord.pack(.disabled))
    var peak: Float = 0
    for frame in 0..<frames {
        let gain = state.mode == .mixing ? state.ramp.advance(toward: target) : 1
        // 静音与滑杆归零共用目标值；在所有音效之后淡出，连已经存在的尾音一起关闭。
        let outputGate = state.mode == .mixing
            ? state.silenceRamp.advance(toward: target == 0 ? 0 : 1) : 1
        let effectsActive = state.mode == .mixing && state.effects.beginFrame()
        if effectsActive {
            var processed = (left: Float(0), right: Float(0))
            var channelOffset = 0
            for i in ins.indices {
                let source = ins[i].mData!.assumingMemoryBound(to: Float.self)
                let channels = Int(ins[i].mNumberChannels)
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    let dry = source[index] * gain
                    let sample = state.effects.processPrelimiter(dry, channel: channelOffset + channel)
                    if channelOffset + channel == 0 { processed.left = sample }
                    else { processed.right = sample }
                }
                channelOffset += channels
            }
            state.effects.processSpatial(&processed, channels: totalChannels)
            state.effects.processDynamics(&processed, channels: totalChannels)
            let limited = state.effects.limitFrame(&processed, channels: totalChannels)
            let rendered = (limited.0 * outputGate, limited.1 * outputGate)
            peak = max(peak, abs(rendered.0), abs(rendered.1))
            channelOffset = 0
            for i in ins.indices {
                let destination = outs[i].mData!.assumingMemoryBound(to: Float.self)
                let channels = Int(ins[i].mNumberChannels)
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    destination[index] = channelOffset + channel == 0 ? rendered.0 : rendered.1
                }
                channelOffset += channels
            }
        } else {
            for i in ins.indices {
                let source = ins[i].mData!.assumingMemoryBound(to: Float.self)
                let destination = outs[i].mData!.assumingMemoryBound(to: Float.self)
                let channels = Int(ins[i].mNumberChannels)
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    let sample = source[index] * gain * outputGate
                    if sample.isFinite { peak = max(peak, abs(sample)) }
                    // 只读计量不重放捕获音频，避免原始声音与本进程的输出叠加。
                    if state.mode == .mixing { destination[index] = sample }
                }
            }
        }
    }
    state.peak.publish(peak)
    state.callbacks.wrappingAdd(1, ordering: .relaxed)
    return noErr
}

/// 一次用户明确启用的、指向固定输出的音频接管。
/// 不支持的格式直接拒绝，绝不另建 mixdown/后备输出链路。
@MainActor
public final class ProcessAudioSession: ApplicationAudioSession {
    public private(set) var group: AudioProcessGroup
    public private(set) var output: AudioOutput
    public let mode: ApplicationAudioMode
    public private(set) var gain: Float = 1
    public private(set) var muted = false
    private var effectSettings: AppAudioEffectSettings?
    private let hardware: ProcessAudioHardware
    private let resources: ProcessAudioResources
    private var renderState: RenderState? { resources.renderState }
    private var activityWatchdog = AudioActivityWatchdog()
    public private(set) var playbackRoute: ApplicationPlaybackRoute
    public var isActive: Bool { resources.isActive }
    public var isReleased: Bool { resources.isReleased }
    public var isSuspendedForOutputChange: Bool { resources.isSuspended }
    public let supportsContinuousOutputSwitch = false
    public var resourceSnapshot: AudioSessionResourceSnapshot { resources.snapshot }

    public convenience init(group: AudioProcessGroup, output: AudioOutput,
                playbackRoute: ApplicationPlaybackRoute? = nil,
                mode: ApplicationAudioMode = .mixing) {
        self.init(group: group, output: output, playbackRoute: playbackRoute, mode: mode, hardware: .live)
    }

    init(group: AudioProcessGroup, output: AudioOutput, playbackRoute: ApplicationPlaybackRoute? = nil,
         mode: ApplicationAudioMode = .mixing, hardware: ProcessAudioHardware) {
        self.group = group
        self.output = output
        self.playbackRoute = playbackRoute ?? .single(output)
        self.mode = mode
        self.hardware = hardware
        resources = ProcessAudioResources(hardware: hardware)
    }

    /// 只消费最近音频回调的真实峰值；未启动或布局失效时不伪造静音读数。
    public func consumePeak() -> Float? {
        guard isActive, let renderState,
              renderState.outputEnabled.load(ordering: .acquiring),
              !renderState.fault.load(ordering: .relaxed),
              renderState.callbacks.load(ordering: .relaxed) > 0 else { return nil }
        return renderState.peak.consume()
    }

    /// 两种模式始终明确区分：混音来源持续静音，只读电平绝不静音来源。
    /// 纯描述构建可离线测试，不需要访问 HAL 或猜测可用设备。
    static func makeTapDescription(group: AudioProcessGroup, route: ApplicationPlaybackRoute,
                                   mode: ApplicationAudioMode, suspended: Bool) -> CATapDescription {
        let description = CATapDescription(processes: group.objectIDs, deviceUID: route.tapDeviceUID, stream: 0)
        description.uuid = UUID()
        description.name = "Auxmo application audio"
        description.isPrivate = true
        // mutedWhenTapped 在停止读取后会恢复原声；持续静音必须使用 muted。
        description.muteBehavior = mode == .mixing ? .muted : .unmuted
        if suspended {
            description.deviceUID = nil
            description.stream = nil
        }
        return description
    }

    /// 目标尚不可用时只接管静音，不创建输出聚合，不启动 I/O，不读取或重放任何样本。
    public func startSuspended() throws {
        guard mode == .mixing, !group.objectIDs.isEmpty else {
            throw AudioFailure("只有具有已注册进程的混音会话才能等待所选输出")
        }
        guard isReleased else { throw AudioFailure("该应用已接管，不能重复启动") }
        let description = Self.makeTapDescription(group: group, route: playbackRoute, mode: mode, suspended: true)
        try resources.createTap(description)
    }

    /// 更新同一应用的进程集合，不销毁旧 tap；暂停期间新增的 helper 也必须留在静音范围内。
    public func updateProcesses(to group: AudioProcessGroup) throws {
        guard let current = resources.description,
              group.id == self.group.id, group.bundleID == self.group.bundleID,
              !group.objectIDs.isEmpty else {
            throw AudioFailure("应用静音捕获的进程身份无效，未改变会话")
        }
        let description = Self.makeTapDescription(group: group, route: playbackRoute, mode: mode,
                                                  suspended: current.deviceUID == nil)
        description.uuid = current.uuid
        try resources.updateTap(description)
        self.group = group
    }

    public func start() throws {
        let interval = AudioSwitchTrace.begin("StartApplicationSession")
        defer { AudioSwitchTrace.end("StartApplicationSession", interval) }
        guard !group.objectIDs.isEmpty else { throw AudioFailure("应用尚未创建音频流") }
        guard isReleased else { throw AudioFailure("该应用已接管，不能重复启动") }
        try validateOutputRoute(output, playbackRoute: playbackRoute)
        do {
            try validateRoutes(playbackRoute)
            // 独立输出设备没有输入流，且仅有一个输出流，因此它的全局 stream 索引为 0。
            // 显式限定来源，绝不把进程在其他设备上的声音混到系统默认输出。
            let description = Self.makeTapDescription(group: group, route: playbackRoute,
                                                       mode: mode, suspended: false)
            try resources.createTap(description)
            try resources.startPlayback(route: playbackRoute, mode: mode, gain: muted ? 0 : gain, effect: effectSettings)
            activityWatchdog = AudioActivityWatchdog()
        } catch {
            if mode == .mixing, resources.hasTap {
                // 已创建的成功 tap 正在静音来源；启动失败时只拆重放端，
                // 不能为了清理错误把静音一起释放，否则应用会立即恢复原声。
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

    /// 输出切换只重建重放聚合，保留仍在静音来源的 process tap。
    /// 这样静音应用不会在旧 tap 销毁与新 tap 建立之间短暂漏出原声。
    public func suspendForOutputChange() throws {
        let interval = AudioSwitchTrace.begin("SuspendApplicationOutput")
        defer { AudioSwitchTrace.end("SuspendApplicationOutput", interval) }
        guard mode == .mixing, let current = resources.description else {
            throw AudioFailure("应用音频会话尚未启动，不能暂停输出路由")
        }
        // 先成功建立无设备绑定的持续静音，再停重放。属性写入失败时不冒充已暂停。
        let description = Self.makeTapDescription(group: group, route: playbackRoute, mode: mode, suspended: true)
        description.uuid = current.uuid
        resources.silencePlayback()
        var failures: [AudioFailure] = []
        do { try resources.updateTap(description) }
        catch { failures.append(HAL.operationFailure(error, operation: "更新应用静音捕获")) }
        // 解绑失败仍尝试关停重放；但停止失败后不销毁依赖它的回调、上下文和 tap。
        do { try resources.stopPlayback() }
        catch { failures.append(HAL.operationFailure(error, operation: "暂停应用重放")) }
        if !failures.isEmpty { throw AudioResourceFailures(failures: failures) }
    }

    public func switchOutput(to output: AudioOutput, playbackRoute: ApplicationPlaybackRoute) throws {
        let interval = AudioSwitchTrace.begin("SwitchApplicationOutput")
        defer { AudioSwitchTrace.end("SwitchApplicationOutput", interval) }
        guard let description = resources.description,
              (isActive || isSuspendedForOutputChange) else {
            throw AudioFailure("应用音频会话尚未启动，不能切换输出")
        }
        try validateOutputRoute(output, playbackRoute: playbackRoute)
        do {
            try validateRoutes(playbackRoute)
            try resources.stopPlayback()

            // process tap 始终保留；用新对象更新来源设备，HAL 写入失败时不能污染已保存的描述。
            let nextDescription = Self.makeTapDescription(group: group, route: playbackRoute,
                                                           mode: mode, suspended: false)
            nextDescription.uuid = description.uuid
            try resources.updateTap(nextDescription)
            try resources.startPlayback(route: playbackRoute, mode: mode, gain: muted ? 0 : gain, effect: effectSettings)
            activityWatchdog = AudioActivityWatchdog()
            self.output = output
            self.playbackRoute = playbackRoute
        } catch {
            // 新目标失败或格式未收敛，都先回到无设备绑定的持续静音状态。
            // 暂停本身失败必须如实抛出，不能把残留的播放端标成已暂停。
            do { try suspendForOutputChange() }
            catch let cleanupError {
                throw AudioResourceFailures([error, cleanupError], operation: "切换应用输出")
            }
            throw error
        }
    }

    private func validateOutputRoute(_ output: AudioOutput,
                                     playbackRoute: ApplicationPlaybackRoute) throws {
        guard !output.isAggregate || output.isAuxmoMultiOutput else {
            throw AudioFailure("第三方聚合输出暂不支持 APP 独立音量或实时电平")
        }
        if output.isAuxmoMultiOutput {
            let targets = playbackRoute.playbackDeviceUIDs
            guard playbackRoute.sourceOutputUID == output.uid,
                  !targets.isEmpty,
                  Set(targets).count == targets.count,
                  targets.contains(playbackRoute.mainDeviceUID),
                  playbackRoute.isStacked == (targets.count > 1),
                  playbackRoute.tapDeviceUID != output.uid,
                  playbackRoute.acceptedProcessRouteUIDs.contains(output.uid),
                  targets.allSatisfy({ playbackRoute.acceptedProcessRouteUIDs.contains($0) }) else {
                throw AudioFailure("多设备输出缺少真实成员，无法启动 APP 独立音量")
            }
        } else {
            guard playbackRoute.tapDeviceUID == output.uid,
                  playbackRoute.playbackDeviceUIDs == [output.uid],
                  !playbackRoute.isStacked,
                  playbackRoute.acceptedProcessRouteUIDs == [output.uid] else {
                throw AudioFailure("单设备输出的 APP 音频路由无效")
            }
        }
        try hardware.validateOutput(output)
    }

    public static func validate(_ format: AudioStreamBasicDescription) throws {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              format.mBitsPerChannel == 32, (1...2).contains(format.mChannelsPerFrame),
              format.mFramesPerPacket == 1,
              format.mBytesPerFrame == (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 4 : 4 * format.mChannelsPerFrame),
              format.mBytesPerPacket == format.mBytesPerFrame,
              format.mSampleRate.isFinite, format.mSampleRate > 0 else {
            throw AudioFailure("当前仅支持原生 Float32 单声道或双声道 PCM；未启用音频接管")
        }
    }

    /// 蓝牙从立体声媒体模式切到通话模式会改变采样率和声道数，这是同设备的原生格式变化。
    /// 不做重采样或另换后端；通知模型停止旧会话，再按当前真实格式重建，并保留增益/静音。
    public static func requireMatchingPCM(captured: AudioStreamBasicDescription,
                                          current: AudioStreamBasicDescription) throws {
        try validate(captured)
        try validate(current)
        guard captured.mSampleRate == current.mSampleRate,
              captured.mChannelsPerFrame == current.mChannelsPerFrame,
              captured.mFormatFlags == current.mFormatFlags,
              captured.mBytesPerFrame == current.mBytesPerFrame,
              captured.mBytesPerPacket == current.mBytesPerPacket else {
            let detail = "capture=\(captured.mSampleRate)Hz/\(captured.mChannelsPerFrame)ch/flags=\(captured.mFormatFlags); output=\(current.mSampleRate)Hz/\(current.mChannelsPerFrame)ch/flags=\(current.mFormatFlags)"
            throw ApplicationRoutePending(reason: .formatChange, detail: detail)
        }
    }

    public func setGain(_ value: Float) throws {
        guard value.isFinite, (0...1).contains(value) else { throw AudioFailure("应用增益必须在 0～100% 之间") }
        gain = value; publishGain()
    }
    public func setMuted(_ value: Bool) { muted = value; publishGain() }
    public func setSafetyMute(_ value: Bool) throws {
        // mixing 的静音由用户意图与全局状态合成为 setMuted；这里只处理只读计量 tap。
        guard mode == .metering, let current = resources.description else { return }
        let description = Self.makeTapDescription(group: group, route: playbackRoute,
                                                  mode: mode, suspended: current.deviceUID == nil)
        description.uuid = current.uuid
        description.muteBehavior = value ? .muted : .unmuted
        do {
            try resources.updateTap(description)
        } catch {
            throw HAL.operationFailure(error, operation: "更新全局安全静音")
        }
    }
    private func publishGain() { renderState?.target.store((muted ? Float(0) : gain).bitPattern, ordering: .relaxed) }
    public func setEffect(_ settings: AppAudioEffectSettings?) {
        effectSettings = mode == .mixing ? settings : nil
        renderState?.setEffect(effectSettings)
    }

    private func validateRoutes(_ route: ApplicationPlaybackRoute) throws {
        // HAL 默认路由确认后，各 APP 的进程对象仍可能稍晚更新；只读取事实，不阻塞主线程。
        let routes = try processOutputRoutes()
        guard route.acceptsActiveProcessRoutes(routes) else {
            let actual = routes.filter(\.isRunningOutput).flatMap(\.deviceUIDs).joined(separator: ",")
            throw ApplicationRoutePending(detail: "expected=\(route.sourceOutputUID); actual=\(actual)")
        }
    }

    private func processOutputRoutes() throws -> [ProcessOutputRoute] {
        try hardware.processRoutes(group)
    }

    public func checkHealth(expectingAudio: Bool = true) throws {
        guard isActive, renderState?.outputEnabled.load(ordering: .acquiring) == true,
              let deviceID = resources.playbackDeviceID else {
            throw AudioFailure("音频接管未成功启动，正在重试释放残留资源")
        }
        try validateRoutes(playbackRoute)
        // 自定义子集的主时钟可能不是公开聚合主成员，必须读取本会话实际创建的重放聚合格式。
        let actual = try hardware.outputFormat(deviceID)
        guard let activeFormat = resources.activeFormat else { throw AudioFailure("音频会话缺少已确认的 PCM 格式") }
        try Self.requireMatchingPCM(captured: activeFormat, current: actual)
        if renderState?.fault.load(ordering: .relaxed) == true {
            throw AudioFailure("实时输入/输出缓冲布局不匹配，已请求停止接管")
        }
        if let state = renderState,
           activityWatchdog.isStalled(expectingAudio: expectingAudio,
                                      callbacks: state.callbacks.load(ordering: .relaxed), at: Date()) {
            throw AudioFailure("未收到音频回调，请检查录制授权和应用播放状态")
        }
    }

    public func stop() throws {
        let interval = AudioSwitchTrace.begin("StopApplicationSession")
        defer { AudioSwitchTrace.end("StopApplicationSession", interval) }
        try resources.stop()
        effectSettings = nil
    }
}
