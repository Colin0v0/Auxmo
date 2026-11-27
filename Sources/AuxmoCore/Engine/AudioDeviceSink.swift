import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// 物理输出设备的 HAL 边界；每台在线物理设备最多持有一个共享 Sink IOProc，不再为每个应用创建输出聚合。
@MainActor
public struct AudioSinkHardware {
    public var outputFormat: (AudioDeviceID) throws -> AudioStreamBasicDescription
    public var createIO: (AudioDeviceID, @escaping AudioDeviceIOProc, UnsafeMutableRawPointer) throws -> AudioDeviceIOProcID
    public var startIO: (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus
    public var stopIO: (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus
    public var destroyIO: (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus
    public var deviceExists: (AudioDeviceID) throws -> Bool
    public var validateOutput: (AudioOutput) throws -> Void

    public init(outputFormat: @escaping (AudioDeviceID) throws -> AudioStreamBasicDescription,
                createIO: @escaping (AudioDeviceID, @escaping AudioDeviceIOProc, UnsafeMutableRawPointer) throws -> AudioDeviceIOProcID,
                startIO: @escaping (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus,
                stopIO: @escaping (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus,
                destroyIO: @escaping (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus,
                deviceExists: @escaping (AudioDeviceID) throws -> Bool,
                validateOutput: @escaping (AudioOutput) throws -> Void) {
        self.outputFormat = outputFormat
        self.createIO = createIO
        self.startIO = startIO
        self.stopIO = stopIO
        self.destroyIO = destroyIO
        self.deviceExists = deviceExists
        self.validateOutput = validateOutput
    }

    public static var live: Self {
        Self(
            outputFormat: {
                try HAL.read($0, HAL.address(kAudioDevicePropertyStreamFormat,
                                             scope: kAudioDevicePropertyScopeOutput),
                             initial: AudioStreamBasicDescription())
            },
            createIO: { deviceID, callback, context in
                var ioProc: AudioDeviceIOProcID?
                try HAL.check(AudioDeviceCreateIOProcID(deviceID, callback, context, &ioProc), "注册物理输出回调")
                guard let ioProc else { throw AudioFailure("系统未返回输出回调句柄") }
                return ioProc
            },
            startIO: AudioDeviceStart,
            stopIO: AudioDeviceStop,
            destroyIO: AudioDeviceDestroyIOProcID,
            deviceExists: HAL.deviceExists,
            validateOutput: { output in
                guard !output.isAggregate else {
                    throw AudioFailure("引擎输出端仅绑定真实物理设备，不嵌套聚合设备")
                }
                guard try HAL.ids(output.id, HAL.address(kAudioDevicePropertyStreams,
                                                         scope: kAudioDevicePropertyScopeInput)).isEmpty else {
                    throw AudioFailure("本阶段仅支持独立输出设备，不接管带输入流的双工音频接口")
                }
                guard try HAL.ids(output.id, HAL.address(kAudioDevicePropertyStreams,
                                                         scope: kAudioDevicePropertyScopeOutput)).count == 1 else {
                    throw AudioFailure("本阶段仅支持单个输出流的设备")
                }
            }
        )
    }
}

/// 单个输入边槽位：由状态原子字严格划分主线程写入期、音频线程执行期和主线程回收期。
final class SinkEdgeSlot {
    enum State: UInt8 {
        case empty = 0
        case active = 1
        case retired = 2
    }

    let state = Atomic<UInt8>(State.empty.rawValue)
    let disconnecting = Atomic<Bool>(false)
    var rawRing: UnsafeMutableRawPointer?
    var reader: AudioSinkEdgeReader

    init(sampleRate: Double) {
        reader = AudioSinkEdgeReader(sinkSampleRate: sampleRate, initialGain: 0)
    }
}

/// 物理设备 Sink 的实时渲染上下文；预分配全部混音缓冲与边槽位，回调全程无锁无分配。
final class SinkRenderState {
    static let maxSlots = 64
    static let scratchChunkFrames = 4_096

    let sampleRate: Double
    let outputEnabled = Atomic<Bool>(true)
    let fault = Atomic<Bool>(false)
    let callbacks = Atomic<UInt64>(0)
    let peak = AudioPeakMailbox()
    let slots: [SinkEdgeSlot]

    private let leftScratch: UnsafeMutablePointer<Float>
    private let rightScratch: UnsafeMutablePointer<Float>
    private var limiterGain: Float = 1
    private let limiterReleaseStep: Float

    init(sampleRate: Double) {
        let validRate = (sampleRate.isFinite && sampleRate > 0) ? sampleRate : 48_000
        self.sampleRate = validRate
        self.limiterReleaseStep = Float(1 / max(1, validRate * 0.08))
        self.slots = (0..<Self.maxSlots).map { _ in SinkEdgeSlot(sampleRate: validRate) }
        self.leftScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchChunkFrames)
        self.rightScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchChunkFrames)
        self.leftScratch.initialize(repeating: 0, count: Self.scratchChunkFrames)
        self.rightScratch.initialize(repeating: 0, count: Self.scratchChunkFrames)
    }

    deinit {
        leftScratch.deallocate()
        rightScratch.deallocate()
    }

    @inline(__always)
    func renderChunk(frames: Int, totalChannels: Int) -> (UnsafePointer<Float>, UnsafePointer<Float>, Float) {
        let byteCount = frames * MemoryLayout<Float>.size
        memset(leftScratch, 0, byteCount)
        memset(rightScratch, 0, byteCount)

        for slot in slots {
            guard slot.state.load(ordering: .acquiring) == SinkEdgeSlot.State.active.rawValue,
                  let rawRing = slot.rawRing else {
                continue
            }
            let ring = Unmanaged<AudioBroadcastRingBuffer>.fromOpaque(rawRing).takeUnretainedValue()
            let disconnecting = slot.disconnecting.load(ordering: .acquiring)
            let finished = slot.reader.mixIntoBus(
                from: ring,
                leftBus: leftScratch,
                rightBus: rightScratch,
                frames: frames,
                sinkSampleRate: sampleRate,
                disconnecting: disconnecting
            )
            if finished {
                slot.state.store(SinkEdgeSlot.State.retired.rawValue, ordering: .releasing)
            }
        }

        var chunkPeak: Float = 0
        for frame in 0..<frames {
            var left = leftScratch[frame]
            var right = totalChannels > 1 ? rightScratch[frame] : left
            if totalChannels == 1 {
                left = (leftScratch[frame] + rightScratch[frame]) * 0.5
                right = left
            }
            let framePeak = max(abs(left), totalChannels > 1 ? abs(right) : 0)
            if framePeak > 0.98 {
                limiterGain = min(limiterGain, 0.98 / framePeak)
            } else {
                limiterGain = min(1, limiterGain + (1 - limiterGain) * limiterReleaseStep)
            }
            left *= limiterGain
            right *= limiterGain
            leftScratch[frame] = left
            rightScratch[frame] = right
            chunkPeak = max(chunkPeak, abs(left), totalChannels > 1 ? abs(right) : 0)
        }
        return (UnsafePointer(leftScratch), UnsafePointer(rightScratch), chunkPeak)
    }
}

let auxmoSinkAudioCallback: AudioDeviceIOProc = { _, _, _, _, output, _, context in
    let outs = UnsafeMutableAudioBufferListPointer(output)
    for buffer in outs {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    guard let context else { return noErr }
    let state = Unmanaged<SinkRenderState>.fromOpaque(context).takeUnretainedValue()
    guard state.outputEnabled.load(ordering: .acquiring) else { return noErr }
    guard !outs.isEmpty else {
        state.fault.store(true, ordering: .relaxed)
        return noErr
    }

    var totalFrames: Int?
    var totalChannels = 0
    for buffer in outs {
        guard buffer.mNumberChannels > 0,
              buffer.mDataByteSize % (4 * buffer.mNumberChannels) == 0 else {
            state.fault.store(true, ordering: .relaxed)
            return noErr
        }
        let count = Int(buffer.mDataByteSize / (4 * buffer.mNumberChannels))
        if let totalFrames, totalFrames != count {
            state.fault.store(true, ordering: .relaxed)
            return noErr
        }
        totalFrames = count
        totalChannels += Int(buffer.mNumberChannels)
        guard buffer.mData != nil else { return noErr }
    }
    guard let frames = totalFrames, (1...2).contains(totalChannels) else {
        state.fault.store(true, ordering: .relaxed)
        return noErr
    }

    var offset = 0
    var maxPeak: Float = 0
    while offset < frames {
        let chunk = min(SinkRenderState.scratchChunkFrames, frames - offset)
        let (leftPtr, rightPtr, chunkPeak) = state.renderChunk(frames: chunk, totalChannels: totalChannels)
        maxPeak = max(maxPeak, chunkPeak)

        var channelCursor = 0
        for buffer in outs {
            let destination = buffer.mData!.assumingMemoryBound(to: Float.self)
            let channels = Int(buffer.mNumberChannels)
            for ch in 0..<channels {
                let globalChannel = channelCursor + ch
                let sourceBus = globalChannel == 0 ? leftPtr : rightPtr
                for f in 0..<chunk {
                    destination[(offset + f) * channels + ch] = sourceBus[f]
                }
            }
            channelCursor += channels
        }
        offset += chunk
    }

    state.peak.publish(maxPeak)
    state.callbacks.wrappingAdd(1, ordering: .relaxed)
    return noErr
}

/// 单个物理输出设备的共享混音与限幅汇聚端。
@MainActor
public final class AudioDeviceSink {
    private final class Callback {
        let deviceID: AudioDeviceID
        let ioProc: AudioDeviceIOProcID
        let renderState: SinkRenderState
        let format: AudioStreamBasicDescription
        private var context: Unmanaged<SinkRenderState>?

        init(deviceID: AudioDeviceID,
             state: SinkRenderState,
             format: AudioStreamBasicDescription,
             createIO: (AudioDeviceID, @escaping AudioDeviceIOProc, UnsafeMutableRawPointer) throws -> AudioDeviceIOProcID) throws {
            self.deviceID = deviceID
            self.renderState = state
            self.format = format
            let context = Unmanaged.passRetained(state)
            do {
                ioProc = try createIO(deviceID, auxmoSinkAudioCallback, context.toOpaque())
            } catch {
                context.release()
                throw error
            }
            self.context = context
        }

        func releaseContextAndRetainedRings() {
            guard context != nil else { return }
            for slot in renderState.slots {
                if let raw = slot.rawRing {
                    Unmanaged<AudioBroadcastRingBuffer>.fromOpaque(raw).release()
                    slot.rawRing = nil
                }
                slot.state.store(SinkEdgeSlot.State.empty.rawValue, ordering: .relaxed)
                slot.disconnecting.store(false, ordering: .relaxed)
            }
            context?.release()
            context = nil
        }

        deinit {
            renderState.outputEnabled.store(false, ordering: .releasing)
        }
    }

    private enum Stage {
        case absent
        case registered(Callback)
        case running(Callback)
    }

    public private(set) var output: AudioOutput
    private let hardware: AudioSinkHardware
    private var stage: Stage = .absent
    /// 主线程侧的槽位到应用 ID 绑定表（实时线程不访问 String/Dictionary）。
    private var slotSourceIDs: [Int: String] = [:]

    public init(output: AudioOutput, hardware: AudioSinkHardware) {
        self.output = output
        self.hardware = hardware
    }

    /// 真实运行时入口在主 actor 内取得 HAL 适配器，避免默认参数跨 actor 读取 `.live`。
    public convenience init(output: AudioOutput) {
        self.init(output: output, hardware: .live)
    }

    private var callback: Callback? {
        switch stage {
        case .absent: return nil
        case .registered(let cb), .running(let cb): return cb
        }
    }

    var renderState: SinkRenderState? { callback?.renderState }
    public var activeFormat: AudioStreamBasicDescription? { callback?.format }
    public var isRunning: Bool { if case .running = stage { return true }; return false }
    public var isReleased: Bool { if case .absent = stage { return true }; return false }

    public var activeSourceIDs: [String] {
        guard let state = renderState else { return [] }
        return slotSourceIDs.compactMap { index, sourceID in
            let slot = state.slots[index]
            guard slot.state.load(ordering: .acquiring) == SinkEdgeSlot.State.active.rawValue,
                  !slot.disconnecting.load(ordering: .acquiring) else { return nil }
            return sourceID
        }.sorted()
    }

    public var hasActiveOrFadingSources: Bool {
        reclaimRetiredSlots()
        return !slotSourceIDs.isEmpty
    }

    public var snapshot: AudioSinkResourceSnapshot {
        reclaimRetiredSlots()
        let stageValue: AudioSinkResourceSnapshot.Stage
        switch stage {
        case .absent: stageValue = .absent
        case .registered: stageValue = .registered
        case .running: stageValue = .running
        }
        var active: [String] = []
        var fading: [String] = []
        if let state = renderState {
            for (index, sourceID) in slotSourceIDs {
                let slot = state.slots[index]
                guard slot.state.load(ordering: .acquiring) == SinkEdgeSlot.State.active.rawValue else { continue }
                if slot.disconnecting.load(ordering: .acquiring) {
                    fading.append(sourceID)
                } else {
                    active.append(sourceID)
                }
            }
        }
        return AudioSinkResourceSnapshot(
            deviceID: output.id,
            uid: output.uid,
            name: output.name,
            stage: stageValue,
            sampleRate: callback?.format.mSampleRate,
            activeSourceIDs: active.sorted(),
            fadingOutSourceIDs: fading.sorted(),
            replayEnabled: renderState?.outputEnabled.load(ordering: .acquiring) == true
        )
    }

    public func startIfNeeded(updatedOutput: AudioOutput? = nil) throws {
        if let updatedOutput, updatedOutput.uid == output.uid {
            if !isReleased, updatedOutput.id != output.id {
                try stop()
            }
            output = updatedOutput
        }
        if isRunning { return }
        if case .registered(let existing) = stage {
            existing.renderState.outputEnabled.store(true, ordering: .releasing)
            try HAL.check(hardware.startIO(existing.deviceID, existing.ioProc), "启动物理输出回调")
            stage = .running(existing)
            return
        }
        try hardware.validateOutput(output)
        let format = try hardware.outputFormat(output.id)
        try ProcessAudioSession.validate(format)
        let state = SinkRenderState(sampleRate: format.mSampleRate)
        let cb = try Callback(deviceID: output.id, state: state, format: format, createIO: hardware.createIO)
        stage = .registered(cb)
        do {
            try HAL.check(hardware.startIO(output.id, cb.ioProc), "启动物理输出回调")
            stage = .running(cb)
        } catch {
            do { try stop() }
            catch let cleanupError {
                throw AudioResourceFailures([error, cleanupError], operation: "启动物理输出设备")
            }
            throw error
        }
    }

    /// 挂载或更新某个 App Source 的环形缓冲输入边（20ms 淡入）。
    public func attachSource(id: String, ring: AudioBroadcastRingBuffer) throws {
        reclaimRetiredSlots()
        guard let state = renderState else {
            throw AudioFailure("物理输出尚未启动，无法接入应用音频流")
        }
        // 若该 Source 同一实例仍在活跃或正在淡出，若是同一个环形缓冲可直接恢复淡入；若换了新缓冲则旧槽继续淡出、另开新槽交叉淡化。
        for (index, existingID) in slotSourceIDs where existingID == id {
            let slot = state.slots[index]
            if slot.state.load(ordering: .acquiring) == SinkEdgeSlot.State.active.rawValue,
               let raw = slot.rawRing {
                let currentRing = Unmanaged<AudioBroadcastRingBuffer>.fromOpaque(raw).takeUnretainedValue()
                if currentRing === ring {
                    slot.disconnecting.store(false, ordering: .releasing)
                    return
                }
                slot.disconnecting.store(true, ordering: .releasing)
            }
        }

        guard let freeIndex = state.slots.indices.first(where: {
            slotSourceIDs[$0] == nil
                && state.slots[$0].state.load(ordering: .acquiring) == SinkEdgeSlot.State.empty.rawValue
        }) else {
            throw AudioFailure("物理输出混音槽位已满，无法接入更多应用流")
        }

        let slot = state.slots[freeIndex]
        slot.rawRing = Unmanaged.passRetained(ring).toOpaque()
        slot.reader.reset(sinkSampleRate: state.sampleRate, initialGain: 0)
        slot.disconnecting.store(false, ordering: .relaxed)
        slotSourceIDs[freeIndex] = id
        slot.state.store(SinkEdgeSlot.State.active.rawValue, ordering: .releasing)
    }

    /// 请求平滑断开某个 App Source 的输入边（由实时回调完成 20ms 淡出后再标记退役）。
    public func detachSource(id: String) {
        reclaimRetiredSlots()
        guard let state = renderState else { return }
        for (index, existingID) in slotSourceIDs where existingID == id {
            let slot = state.slots[index]
            if slot.state.load(ordering: .acquiring) == SinkEdgeSlot.State.active.rawValue {
                slot.disconnecting.store(true, ordering: .releasing)
            }
        }
    }

    /// 回收已完成淡出的槽位，在主线程安全释放环形缓冲引用。
    public func reclaimRetiredSlots() {
        guard let state = renderState else {
            slotSourceIDs.removeAll()
            return
        }
        for (index, _) in Array(slotSourceIDs) {
            let slot = state.slots[index]
            if slot.state.load(ordering: .acquiring) == SinkEdgeSlot.State.retired.rawValue {
                if let raw = slot.rawRing {
                    Unmanaged<AudioBroadcastRingBuffer>.fromOpaque(raw).release()
                    slot.rawRing = nil
                }
                slot.disconnecting.store(false, ordering: .relaxed)
                slot.state.store(SinkEdgeSlot.State.empty.rawValue, ordering: .releasing)
                slotSourceIDs.removeValue(forKey: index)
            }
        }
    }

    public func checkHealth() throws {
        reclaimRetiredSlots()
        guard isRunning,
              let cb = callback,
              cb.renderState.outputEnabled.load(ordering: .acquiring) else {
            throw AudioFailure("物理输出未处于活动状态")
        }
        let actual = try hardware.outputFormat(cb.deviceID)
        try ProcessAudioSession.requireMatchingPCM(captured: cb.format, current: actual)
        if cb.renderState.fault.load(ordering: .relaxed) {
            throw AudioFailure("物理输出实时缓冲布局不匹配，已停止混音输出")
        }
    }

    public func silence() {
        renderState?.outputEnabled.store(false, ordering: .releasing)
    }

    public func stop() throws {
        silence()
        if case .running(let cb) = stage {
            try HAL.checkTeardown(hardware.stopIO(cb.deviceID, cb.ioProc), "停止物理输出回调",
                                  isObjectPresent: { try hardware.deviceExists(cb.deviceID) })
            stage = .registered(cb)
        }
        if case .registered(let cb) = stage {
            try HAL.checkTeardown(hardware.destroyIO(cb.deviceID, cb.ioProc), "释放物理输出回调",
                                  isObjectPresent: { try hardware.deviceExists(cb.deviceID) })
            cb.releaseContextAndRetainedRings()
            slotSourceIDs.removeAll()
            stage = .absent
        }
    }
}
