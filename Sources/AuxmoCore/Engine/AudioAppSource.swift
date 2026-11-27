import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// 应用音频源捕获侧的 HAL 边界；仅创建私有捕获聚合读取 Process Tap，不包含任何物理输出子设备。
@MainActor
public struct AudioSourceHardware {
    public var createTap: (CATapDescription) throws -> AudioObjectID
    public var updateTap: (AudioObjectID, CATapDescription) throws -> Void
    public var tapFormat: (AudioObjectID) throws -> AudioStreamBasicDescription
    public var createCaptureAggregate: ([String: Any]) throws -> AudioDeviceID
    public var captureFormat: (AudioDeviceID) throws -> AudioStreamBasicDescription
    public var createIO: (AudioDeviceID, @escaping AudioDeviceIOProc, UnsafeMutableRawPointer) throws -> AudioDeviceIOProcID
    public var startIO: (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus
    public var stopIO: (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus
    public var destroyIO: (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus
    public var destroyAggregate: (AudioDeviceID) -> OSStatus
    public var destroyTap: (AudioObjectID) -> OSStatus
    public var deviceExists: (AudioDeviceID) throws -> Bool
    public var tapExists: (AudioObjectID) throws -> Bool
    public var processRoutes: (AudioProcessGroup) throws -> [ProcessOutputRoute]

    public init(createTap: @escaping (CATapDescription) throws -> AudioObjectID,
                updateTap: @escaping (AudioObjectID, CATapDescription) throws -> Void,
                tapFormat: @escaping (AudioObjectID) throws -> AudioStreamBasicDescription,
                createCaptureAggregate: @escaping ([String: Any]) throws -> AudioDeviceID,
                captureFormat: @escaping (AudioDeviceID) throws -> AudioStreamBasicDescription,
                createIO: @escaping (AudioDeviceID, @escaping AudioDeviceIOProc, UnsafeMutableRawPointer) throws -> AudioDeviceIOProcID,
                startIO: @escaping (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus,
                stopIO: @escaping (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus,
                destroyIO: @escaping (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus,
                destroyAggregate: @escaping (AudioDeviceID) -> OSStatus,
                destroyTap: @escaping (AudioObjectID) -> OSStatus,
                deviceExists: @escaping (AudioDeviceID) throws -> Bool,
                tapExists: @escaping (AudioObjectID) throws -> Bool,
                processRoutes: @escaping (AudioProcessGroup) throws -> [ProcessOutputRoute]) {
        self.createTap = createTap
        self.updateTap = updateTap
        self.tapFormat = tapFormat
        self.createCaptureAggregate = createCaptureAggregate
        self.captureFormat = captureFormat
        self.createIO = createIO
        self.startIO = startIO
        self.stopIO = stopIO
        self.destroyIO = destroyIO
        self.destroyAggregate = destroyAggregate
        self.destroyTap = destroyTap
        self.deviceExists = deviceExists
        self.tapExists = tapExists
        self.processRoutes = processRoutes
    }

    public static var live: Self {
        Self(
            createTap: { description in
                var tapID: AudioObjectID = 0
                try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "创建应用音频捕获")
                return tapID
            },
            updateTap: { tapID, description in
                try HAL.write(tapID, HAL.address(kAudioTapPropertyDescription), value: description,
                              operation: "更新应用静音捕获")
            },
            tapFormat: {
                try HAL.read($0, HAL.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription())
            },
            createCaptureAggregate: { description in
                var deviceID: AudioDeviceID = 0
                try HAL.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID), "创建应用捕获聚合")
                return deviceID
            },
            captureFormat: {
                try HAL.read($0, HAL.address(kAudioDevicePropertyStreamFormat, scope: kAudioDevicePropertyScopeInput),
                             initial: AudioStreamBasicDescription())
            },
            createIO: { deviceID, callback, context in
                var ioProc: AudioDeviceIOProcID?
                try HAL.check(AudioDeviceCreateIOProcID(deviceID, callback, context, &ioProc), "创建应用捕获回调")
                guard let ioProc else { throw AudioFailure("系统未返回捕获回调句柄") }
                return ioProc
            },
            startIO: AudioDeviceStart,
            stopIO: AudioDeviceStop,
            destroyIO: AudioDeviceDestroyIOProcID,
            destroyAggregate: AudioHardwareDestroyAggregateDevice,
            destroyTap: AudioHardwareDestroyProcessTap,
            deviceExists: HAL.deviceExists,
            tapExists: HAL.tapExists,
            processRoutes: { group in
                try group.objectIDs.map { object in
                    let running: UInt32 = try HAL.read(object, HAL.address(kAudioProcessPropertyIsRunningOutput), initial: 0)
                    let devices = try HAL.ids(object, HAL.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput))
                    return ProcessOutputRoute(
                        isRunningOutput: running != 0,
                        deviceUIDs: try devices.map { try HAL.string($0, kAudioDevicePropertyDeviceUID) }
                    )
                }
            }
        )
    }
}

/// 单个 App Source 的实时捕获与节点链上下文：Tap 输入 → Gain/Mute → EQ/Spatial/Dynamics → MeterProbe → RingBuffer。
final class SourceRenderState {
    static let maxChunkFrames = 4_096

    let captureEnabled = Atomic<Bool>(true)
    let target = Atomic<UInt32>(Float(1).bitPattern)
    let effectWord = Atomic<UInt64>(AppAudioEffectParameterWord.pack(.disabled))
    let spatialWord = Atomic<UInt64>(AppAudioSpatialParameterWord.pack(.disabled))
    let dynamicsWord = Atomic<UInt64>(AppAudioDynamicsParameterWord.pack(.disabled))
    let fault = Atomic<Bool>(false)
    let callbacks = Atomic<UInt64>(0)
    let peak = AudioPeakMailbox()
    let mode: ApplicationAudioMode
    let ringBuffer: AudioBroadcastRingBuffer

    var ramp: GainRamp
    var silenceRamp: GainRamp
    var effects: AppAudioEffectDSP
    let scratchStereo: UnsafeMutablePointer<Float>

    init(sampleRate: Double,
         initialGain: Float = 0,
         mode: ApplicationAudioMode,
         effect: AppAudioEffectSettings?,
         ringBuffer: AudioBroadcastRingBuffer) {
        self.mode = mode
        self.ringBuffer = ringBuffer
        self.ringBuffer.setSampleRate(sampleRate)
        self.ringBuffer.setActive(mode == .mixing)
        self.ramp = GainRamp(sampleRate: sampleRate, initial: initialGain)
        self.silenceRamp = GainRamp(sampleRate: sampleRate, initial: initialGain == 0 ? 0 : 1)
        self.effects = AppAudioEffectDSP(sampleRate: sampleRate)
        self.scratchStereo = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxChunkFrames * 2)
        self.scratchStereo.initialize(repeating: 0, count: Self.maxChunkFrames * 2)
        setEffect(mode == .mixing ? effect : nil)
    }

    deinit {
        scratchStereo.deallocate()
    }

    func setEffect(_ settings: AppAudioEffectSettings?) {
        effectWord.store(AppAudioEffectParameterWord.pack(settings), ordering: .relaxed)
        spatialWord.store(AppAudioSpatialParameterWord.pack(settings), ordering: .relaxed)
        dynamicsWord.store(AppAudioDynamicsParameterWord.pack(settings), ordering: .relaxed)
    }
}

let auxmoSourceCaptureCallback: AudioDeviceIOProc = { _, _, input, _, output, _, context in
    let outs = UnsafeMutableAudioBufferListPointer(output)
    for buffer in outs {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    guard let context else { return noErr }
    let state = Unmanaged<SourceRenderState>.fromOpaque(context).takeUnretainedValue()
    guard state.captureEnabled.load(ordering: .acquiring) else { return noErr }

    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard !ins.isEmpty else {
        state.fault.store(true, ordering: .relaxed)
        return noErr
    }

    var totalFrames: Int?
    var totalChannels = 0
    for source in ins {
        guard source.mNumberChannels > 0,
              source.mDataByteSize % (4 * source.mNumberChannels) == 0 else {
            state.fault.store(true, ordering: .relaxed)
            return noErr
        }
        let count = Int(source.mDataByteSize / (4 * source.mNumberChannels))
        if let totalFrames, totalFrames != count {
            state.fault.store(true, ordering: .relaxed)
            return noErr
        }
        totalFrames = count
        totalChannels += Int(source.mNumberChannels)
        guard source.mData != nil else { return noErr }
    }

    guard let frames = totalFrames, (1...2).contains(totalChannels) else {
        state.fault.store(true, ordering: .relaxed)
        return noErr
    }

    let target = Float(bitPattern: state.target.load(ordering: .relaxed))
    let effectWord = state.mode == .mixing
        ? state.effectWord.load(ordering: .relaxed)
        : AppAudioEffectParameterWord.pack(.disabled)
    let spatialWord = state.mode == .mixing
        ? state.spatialWord.load(ordering: .relaxed)
        : AppAudioSpatialParameterWord.pack(.disabled)
    let dynamicsWord = state.mode == .mixing
        ? state.dynamicsWord.load(ordering: .relaxed)
        : AppAudioDynamicsParameterWord.pack(.disabled)

    state.effects.beginBuffer(effectWord: effectWord, spatialWord: spatialWord, dynamicsWord: dynamicsWord)

    var peak: Float = 0
    var frameOffset = 0
    while frameOffset < frames {
        let chunk = min(SourceRenderState.maxChunkFrames, frames - frameOffset)
        for localFrame in 0..<chunk {
            let frame = frameOffset + localFrame
            let gain = state.mode == .mixing ? state.ramp.advance(toward: target) : 1
            let outputGate = state.mode == .mixing
                ? state.silenceRamp.advance(toward: target == 0 ? 0 : 1)
                : 1
            let effectsActive = state.mode == .mixing && state.effects.beginFrame()

            var rawLeft: Float = 0
            var rawRight: Float = 0
            var channelOffset = 0
            for i in ins.indices {
                let source = ins[i].mData!.assumingMemoryBound(to: Float.self)
                let channels = Int(ins[i].mNumberChannels)
                for ch in 0..<channels {
                    let value = source[frame * channels + ch]
                    if channelOffset + ch == 0 { rawLeft = value }
                    else { rawRight = value }
                }
                channelOffset += channels
            }
            if totalChannels == 1 { rawRight = rawLeft }

            let renderedLeft: Float
            let renderedRight: Float
            if effectsActive {
                let dryLeft = rawLeft * gain
                let dryRight = rawRight * gain
                var processed = (
                    left: state.effects.processPrelimiter(dryLeft, channel: 0),
                    right: state.effects.processPrelimiter(dryRight, channel: 1)
                )
                state.effects.processSpatial(&processed, channels: 2)
                state.effects.processDynamics(&processed, channels: 2)
                let limited = state.effects.limitFrame(&processed, channels: 2)
                renderedLeft = limited.0 * outputGate
                renderedRight = limited.1 * outputGate
            } else {
                let sL = rawLeft * gain * outputGate
                let sR = rawRight * gain * outputGate
                renderedLeft = sL.isFinite ? sL : 0
                renderedRight = sR.isFinite ? sR : 0
            }

            if renderedLeft.isFinite { peak = max(peak, abs(renderedLeft)) }
            if totalChannels > 1, renderedRight.isFinite { peak = max(peak, abs(renderedRight)) }
            state.scratchStereo[localFrame * 2] = renderedLeft
            state.scratchStereo[localFrame * 2 + 1] = renderedRight
        }

        if state.mode == .mixing {
            let scratch = state.scratchStereo
            state.ringBuffer.writeBlock(frames: chunk) { idx in
                (scratch[idx * 2], scratch[idx * 2 + 1])
            }
        }
        frameOffset += chunk
    }

    state.peak.publish(peak)
    state.callbacks.wrappingAdd(1, ordering: .relaxed)
    return noErr
}

/// 单个应用的捕获与节点链生命周期所有者；Tap 与捕获聚合分离持有，支持无缝路由切换与静音保持。
@MainActor
public final class AudioAppSource {
    private struct Tap {
        let id: AudioObjectID
        let description: CATapDescription
    }

    private final class Callback {
        let deviceID: AudioDeviceID
        let ioProc: AudioDeviceIOProcID
        let renderState: SourceRenderState
        let format: AudioStreamBasicDescription
        private var context: Unmanaged<SourceRenderState>?

        init(deviceID: AudioDeviceID,
             state: SourceRenderState,
             format: AudioStreamBasicDescription,
             createIO: (AudioDeviceID, @escaping AudioDeviceIOProc, UnsafeMutableRawPointer) throws -> AudioDeviceIOProcID) throws {
            self.deviceID = deviceID
            self.renderState = state
            self.format = format
            let context = Unmanaged.passRetained(state)
            do {
                ioProc = try createIO(deviceID, auxmoSourceCaptureCallback, context.toOpaque())
            } catch {
                context.release()
                throw error
            }
            self.context = context
        }

        func releaseContext() {
            context?.release()
            context = nil
        }

        deinit {
            renderState.captureEnabled.store(false, ordering: .releasing)
            renderState.ringBuffer.setActive(false)
        }
    }

    private enum CaptureStage {
        case absent
        case aggregate(AudioDeviceID)
        case registered(Callback)
        case running(Callback)
    }

    private let hardware: AudioSourceHardware
    private let excludedPID: Int32
    private var tap: Tap?
    private var capture: CaptureStage = .absent
    public let ringBuffer: AudioBroadcastRingBuffer

    public init(hardware: AudioSourceHardware,
                excludedPID: Int32 = getpid(),
                ringCapacityFrames: Int = 16_384) {
        self.hardware = hardware
        self.excludedPID = excludedPID
        self.ringBuffer = AudioBroadcastRingBuffer(capacityFrames: ringCapacityFrames)
    }

    /// 真实运行时入口在主 actor 内取得 HAL 适配器，避免默认参数跨 actor 读取 `.live`。
    public convenience init(excludedPID: Int32 = getpid(),
                            ringCapacityFrames: Int = 16_384) {
        self.init(hardware: .live, excludedPID: excludedPID, ringCapacityFrames: ringCapacityFrames)
    }

    var description: CATapDescription? { tap?.description }
    public var hasTap: Bool { tap != nil }
    public var isCapturing: Bool { if case .running = capture { return true }; return false }
    public var isReleased: Bool { !hasTap && captureAbsent }
    public var isSuspended: Bool { hasTap && description?.deviceUID == nil && captureAbsent }
    private var captureAbsent: Bool { if case .absent = capture { return true }; return false }

    private var callback: Callback? {
        switch capture {
        case .absent, .aggregate: return nil
        case .registered(let cb), .running(let cb): return cb
        }
    }

    var renderState: SourceRenderState? { callback?.renderState }
    public var activeFormat: AudioStreamBasicDescription? { callback?.format }
    public var captureDeviceID: AudioDeviceID? {
        switch capture {
        case .absent: return nil
        case .aggregate(let id): return id
        case .registered(let cb), .running(let cb): return cb.deviceID
        }
    }

    public var snapshot: AudioSessionResourceSnapshot {
        let stage: AudioSessionResourceSnapshot.PlaybackStage
        switch capture {
        case .absent: stage = .absent
        case .aggregate: stage = .aggregate
        case .registered: stage = .registered
        case .running: stage = .running
        }
        return AudioSessionResourceSnapshot(
            tapID: tap?.id,
            tapIsUnbound: hasTap && description?.deviceUID == nil,
            playbackStage: stage,
            aggregateID: captureDeviceID,
            replayEnabled: renderState?.captureEnabled.load(ordering: .acquiring) == true
        )
    }

    static func makeTapDescription(group: AudioProcessGroup,
                                   tapDeviceUID: String,
                                   mode: ApplicationAudioMode,
                                   suspended: Bool,
                                   excludedPID: Int32) throws -> CATapDescription {
        guard let sanitized = AudioGraphPlanner.sanitizeGroup(group, excludedPID: excludedPID) else {
            throw AudioFailure("拒绝捕获本进程或空进程组，避免音频回授")
        }
        let description: CATapDescription
        // 引擎源使用进程混音 Tap，不把捕获时钟绑定到某一台物理输出；
        // 这样设备切换只改变 Sink 边，不会因为 Tap 换设备而停止捕获。
        if suspended || tapDeviceUID.isEmpty {
            description = CATapDescription(stereoMixdownOfProcesses: sanitized.objectIDs)
            description.deviceUID = nil
            description.stream = nil
        } else {
            description = CATapDescription(processes: sanitized.objectIDs, deviceUID: tapDeviceUID, stream: 0)
        }
        description.uuid = UUID()
        description.name = "Auxmo Engine Source Tap"
        description.isPrivate = true
        description.muteBehavior = mode == .mixing ? .muted : .unmuted
        return description
    }

    static func captureAggregateDescription(tapUUID: UUID, aggregateUID: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Auxmo Engine Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: NSNumber(value: true),
            kAudioAggregateDeviceTapAutoStartKey: NSNumber(value: true),
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: NSNumber(value: true)
            ]]
        ]
    }

    public func createTap(_ description: CATapDescription) throws {
        guard isReleased else { throw AudioFailure("该应用源已接管，不能重复启动") }
        let tapID = try hardware.createTap(description)
        guard tapID != 0 else { throw AudioFailure("系统未返回应用捕获句柄") }
        tap = Tap(id: tapID, description: description)
    }

    public func updateTap(_ description: CATapDescription) throws {
        guard let tap else { throw AudioFailure("应用捕获尚未创建") }
        do {
            try hardware.updateTap(tap.id, description)
        } catch {
            throw HAL.operationFailure(error, operation: "更新应用静音捕获")
        }
        self.tap = Tap(id: tap.id, description: description)
    }

    public func startCapture(mode: ApplicationAudioMode,
                             gain: Float,
                             effect: AppAudioEffectSettings?) throws {
        guard let tap, captureAbsent else {
            throw AudioFailure("旧捕获资源尚未释放，不能重复启动")
        }
        let format = try hardware.tapFormat(tap.id)
        try ProcessAudioSession.validate(format)
        let aggregateUID = "com.colin0v0.auxmo.tap.src.\(UUID().uuidString)"
        let deviceID = try hardware.createCaptureAggregate(
            Self.captureAggregateDescription(tapUUID: tap.description.uuid, aggregateUID: aggregateUID)
        )
        guard deviceID != 0 else { throw AudioFailure("系统未返回捕获聚合句柄") }
        capture = .aggregate(deviceID)
        try ProcessAudioSession.requireMatchingPCM(captured: format, current: try hardware.captureFormat(deviceID))
        let state = SourceRenderState(
            sampleRate: format.mSampleRate,
            initialGain: 0,
            mode: mode,
            effect: mode == .mixing ? effect : nil,
            ringBuffer: ringBuffer
        )
        state.target.store(gain.bitPattern, ordering: .relaxed)
        let cb = try Callback(deviceID: deviceID, state: state, format: format, createIO: hardware.createIO)
        capture = .registered(cb)
        try HAL.check(hardware.startIO(deviceID, cb.ioProc), "启动应用捕获处理")
        capture = .running(cb)
    }

    public func silenceCapture() {
        renderState?.captureEnabled.store(false, ordering: .releasing)
        ringBuffer.setActive(false)
    }

    public func stopCapture() throws {
        silenceCapture()
        if case .running(let cb) = capture {
            try HAL.checkTeardown(hardware.stopIO(cb.deviceID, cb.ioProc), "停止应用捕获回调",
                                  isObjectPresent: { try hardware.deviceExists(cb.deviceID) })
            capture = .registered(cb)
        }
        if case .registered(let cb) = capture {
            try HAL.checkTeardown(hardware.destroyIO(cb.deviceID, cb.ioProc), "释放应用捕获回调",
                                  isObjectPresent: { try hardware.deviceExists(cb.deviceID) })
            cb.releaseContext()
            capture = .aggregate(cb.deviceID)
        }
        if case .aggregate(let deviceID) = capture {
            try HAL.checkTeardown(hardware.destroyAggregate(deviceID), "释放应用捕获聚合",
                                  isObjectPresent: { try hardware.deviceExists(deviceID) })
            capture = .absent
        }
    }

    public func stop() throws {
        try stopCapture()
        guard let tap else { return }
        try HAL.checkTeardown(hardware.destroyTap(tap.id), "释放应用音频捕获",
                              isObjectPresent: { try hardware.tapExists(tap.id) })
        self.tap = nil
    }
}
