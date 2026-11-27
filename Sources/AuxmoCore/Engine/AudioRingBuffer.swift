import AudioToolbox
import Foundation
import Synchronization

/// 单生产者（App 捕获回调）、多消费者（多个物理设备 Sink 回调）无锁立体声广播环形缓冲。
/// 容量在初始化时一次性分配并清零；实时读写路径零锁、零堆分配、零引用计数变更。
public final class AudioBroadcastRingBuffer: @unchecked Sendable {
    public let capacityFrames: Int
    private let mask: UInt64
    private let storage: UnsafeMutablePointer<Float>
    let writeSequence = Atomic<UInt64>(0)
    let sampleRateBits: Atomic<UInt64>
    let active = Atomic<Bool>(true)

    public init(capacityFrames: Int = 16_384, sampleRate: Double = 48_000) {
        let normalized = Self.nextPowerOfTwo(max(256, capacityFrames))
        self.capacityFrames = normalized
        self.mask = UInt64(normalized - 1)
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: normalized * 2)
        self.storage.initialize(repeating: 0, count: normalized * 2)
        let validRate = (sampleRate.isFinite && sampleRate > 0) ? sampleRate : 48_000
        self.sampleRateBits = Atomic<UInt64>(validRate.bitPattern)
    }

    deinit {
        storage.deallocate()
    }

    public var sampleRate: Double {
        Double(bitPattern: sampleRateBits.load(ordering: .relaxed))
    }

    public func setSampleRate(_ rate: Double) {
        guard rate.isFinite, rate > 0 else { return }
        sampleRateBits.store(rate.bitPattern, ordering: .relaxed)
    }

    public func setActive(_ isActive: Bool) {
        active.store(isActive, ordering: .releasing)
    }

    public var publishedFrames: UInt64 {
        writeSequence.load(ordering: .acquiring)
    }

    /// 供实时捕获回调批量写入已处理好的双声道帧，整块完成后做单次 release 发布。
    @inline(__always)
    func writeBlock(frames: Int, _ produce: (Int) -> (Float, Float)) {
        guard frames > 0 else { return }
        let base = writeSequence.load(ordering: .relaxed)
        for index in 0..<frames {
            let pair = produce(index)
            let slot = Int((base &+ UInt64(index)) & mask) &* 2
            storage[slot] = pair.0.isFinite ? pair.0 : 0
            storage[slot &+ 1] = pair.1.isFinite ? pair.1 : 0
        }
        writeSequence.store(base &+ UInt64(frames), ordering: .releasing)
    }

    /// 供测试或交错立体声/单声道源直接写入样本。
    public func writeInterleaved(_ samples: UnsafePointer<Float>, frames: Int, channels: Int) {
        guard frames > 0, (1...2).contains(channels) else { return }
        writeBlock(frames: frames) { frame in
            if channels == 1 {
                let mono = samples[frame]
                return (mono, mono)
            }
            let offset = frame &* 2
            return (samples[offset], samples[offset &+ 1])
        }
    }

    @inline(__always)
    func samplePair(at frameIndex: UInt64) -> (Float, Float) {
        let slot = Int(frameIndex & mask) &* 2
        return (storage[slot], storage[slot &+ 1])
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value { result <<= 1 }
        return result
    }
}

/// 单个 Sink 上的输入边读取器：维护独立连续读游标、Catmull-Rom 三次重采样、时钟漂移伺服及 20ms 交叉淡入淡出。
/// 实例由所属 Sink 的实时线程在激活期间独占访问，不存在跨 Sink 竞争。
struct AudioSinkEdgeReader {
    private var readCursor: Double = 0
    private var primed = false
    private var smoothedFillError: Double = 0
    private var lastRendered: (Float, Float) = (0, 0)
    var edgeGain: GainRamp

    init(sinkSampleRate: Double, initialGain: Float = 0) {
        edgeGain = GainRamp(sampleRate: max(1, sinkSampleRate), initial: initialGain)
    }

    mutating func reset(sinkSampleRate: Double, initialGain: Float = 0) {
        readCursor = 0
        primed = false
        smoothedFillError = 0
        lastRendered = (0, 0)
        edgeGain = GainRamp(sampleRate: max(1, sinkSampleRate), initial: initialGain)
    }

    /// 将当前边的样本叠加进 Sink 混音总线；当请求断开且淡出至完全静音后返回 `true` 以通知槽位退役。
    @inline(__always)
    mutating func mixIntoBus(from ring: AudioBroadcastRingBuffer,
                             leftBus: UnsafeMutablePointer<Float>,
                             rightBus: UnsafeMutablePointer<Float>,
                             frames: Int,
                             sinkSampleRate: Double,
                             disconnecting: Bool) -> Bool {
        guard frames > 0, sinkSampleRate.isFinite, sinkSampleRate > 0 else {
            return disconnecting
        }
        let sourceActive = ring.active.load(ordering: .acquiring)
        let sourceRateRaw = Double(bitPattern: ring.sampleRateBits.load(ordering: .relaxed))
        let sourceRate = (sourceRateRaw.isFinite && sourceRateRaw > 0) ? sourceRateRaw : sinkSampleRate
        let nominalRatio = sourceRate / sinkSampleRate
        let writeSeq = ring.writeSequence.load(ordering: .acquiring)

        let neededSourceFrames = Int(ceil(Double(frames) * nominalRatio)) + 3
        let targetFill = min(
            ring.capacityFrames / 2,
            max(Int(sourceRate * 0.020), neededSourceFrames * 2)
        )

        if !sourceActive {
            fadeTailIntoBus(leftBus: leftBus, rightBus: rightBus, frames: frames)
            primed = false
            return disconnecting && edgeGain.current == 0
        }

        if !primed {
            guard writeSeq >= UInt64(neededSourceFrames) else {
                if disconnecting {
                    for _ in 0..<frames { _ = edgeGain.advance(toward: 0) }
                    return edgeGain.current == 0
                }
                return false
            }
            let maxSafeAvailable = min(Int(min(writeSeq, UInt64(ring.capacityFrames - 64))), ring.capacityFrames - 64)
            let backoff = max(neededSourceFrames, min(maxSafeAvailable, targetFill))
            readCursor = max(0, Double(writeSeq) - Double(backoff))
            smoothedFillError = 0
            primed = true
        }

        var available = Double(writeSeq) - readCursor
        let maxCapacityWindow = Double(ring.capacityFrames - 128)
        if available > maxCapacityWindow {
            // 消费者落后超过环形窗口安全裕量时重新对齐到目标水位。
            readCursor = max(0, Double(writeSeq) - Double(targetFill))
            available = Double(targetFill)
            smoothedFillError = 0
        }

        if available < Double(neededSourceFrames) {
            // 源应用暂停或回调抖动造成欠载：平滑衰减末样本避免截断爆音，下次重新预热淡入。
            fadeTailIntoBus(leftBus: leftBus, rightBus: rightBus, frames: frames)
            primed = false
            return disconnecting && edgeGain.current == 0
        }

        let fillError = available - Double(targetFill)
        smoothedFillError += 0.05 * (fillError - smoothedFillError)
        // 时钟漂移补偿限制在 ±0.5% 以内，消除异源晶振漂移而不引入可听音高抖动。
        let driftAdjust = max(-0.005, min(0.005, smoothedFillError * 0.000_002))
        let step = nominalRatio * (1.0 + driftAdjust)
        let maxIndex = writeSeq &- 1
        let targetGain: Float = disconnecting ? 0 : 1

        for frame in 0..<frames {
            let gain = edgeGain.advance(toward: targetGain)
            let cursor = max(0, readCursor)
            let base = min(UInt64(cursor), maxIndex)
            let fraction = Float(cursor - Double(base))

            let i0 = base > 0 ? (base &- 1) : 0
            let i1 = base
            let i2 = min(base &+ 1, maxIndex)
            let i3 = min(base &+ 2, maxIndex)

            let p0 = ring.samplePair(at: i0)
            let p1 = ring.samplePair(at: i1)
            let p2 = ring.samplePair(at: i2)
            let p3 = ring.samplePair(at: i3)

            let sampleL = Self.hermite(p0.0, p1.0, p2.0, p3.0, fraction) * gain
            let sampleR = Self.hermite(p0.1, p1.1, p2.1, p3.1, fraction) * gain

            leftBus[frame] += sampleL
            rightBus[frame] += sampleR
            lastRendered = (sampleL, sampleR)
            readCursor += step
        }

        return disconnecting && edgeGain.current == 0
    }

    @inline(__always)
    private mutating func fadeTailIntoBus(leftBus: UnsafeMutablePointer<Float>,
                                          rightBus: UnsafeMutablePointer<Float>,
                                          frames: Int) {
        let fadeFrames = min(frames, 64)
        if fadeFrames > 0, (abs(lastRendered.0) > 0.000_001 || abs(lastRendered.1) > 0.000_001) {
            for i in 0..<fadeFrames {
                let scale = Float(fadeFrames - i - 1) / Float(fadeFrames)
                leftBus[i] += lastRendered.0 * scale
                rightBus[i] += lastRendered.1 * scale
            }
        }
        lastRendered = (0, 0)
        for _ in 0..<frames { _ = edgeGain.advance(toward: 0) }
    }

    @inline(__always)
    static func hermite(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let c0 = p1
        let c1 = 0.5 * (p2 - p0)
        let c2 = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3
        let c3 = 0.5 * (p3 - p0) + 1.5 * (p1 - p2)
        return ((c3 * t + c2) * t + c1) * t + c0
    }
}
