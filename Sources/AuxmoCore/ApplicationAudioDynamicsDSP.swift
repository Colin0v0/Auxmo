import Foundation

/// 将动态和声道设置作为一个原子快照传入回调，避免实时线程访问界面对象。
enum AppAudioDynamicsParameterWord {
    static func pack(_ settings: AppAudioEffectSettings?) -> UInt64 {
        guard let settings, settings.enabled else { return 100 << 3 }
        let mode: UInt64
        switch settings.dynamics {
        case .off: mode = 0
        case .light: mode = 1
        case .strong: mode = 2
        case .night: mode = 3
        }
        let balance = UInt64(Int((settings.channel.balance * 100).rounded()) + 100)
        return mode | (settings.channel.mono ? 4 : 0) | (balance << 3) | (settings.channel.swap ? 1 << 11 : 0)
    }
}

/// 峰值包络压缩与声道混合均为逐帧处理；增益和平衡缓变，避免调整时出现咔哒声。
struct AppAudioDynamicsDSP {
    private var mode: UInt64 = 0
    private var envelope: Float = 0
    private var compressionGain: Float = 1
    private var balance: Float = 0
    private var monoMix: Float = 0
    private var targetBalance: Float = 0
    private var targetMono: Float = 0
    private var swapMix: Float = 0
    private var targetSwap: Float = 0
    private var makeupGain: Float = 1
    private let smoothing: Float
    private let attack: Float
    private let release: Float

    init(sampleRate: Double) {
        smoothing = Float(1 / max(1, sampleRate * 0.02))
        attack = Float(1 - exp(-1 / (sampleRate * 0.01)))
        release = Float(1 - exp(-1 / (sampleRate * 0.25)))
    }

    mutating func beginBuffer(word: UInt64) {
        mode = word & 3
        targetMono = word & 4 == 0 ? 0 : 1
        targetSwap = word & (1 << 11) == 0 ? 0 : 1
        targetBalance = Float(Int((word >> 3) & 255) - 100) / 100
    }

    mutating func reset() {
        envelope = 0
        compressionGain = 1
        balance = 0
        monoMix = 0
        swapMix = 0
        makeupGain = 1
    }

    @inline(__always) mutating func process(_ samples: inout (left: Float, right: Float), channels: Int, wetMix: Float = 1) {
        let dryLeft = samples.left
        let dryRight = samples.right
        balance += max(-smoothing, min(smoothing, targetBalance - balance))
        monoMix += max(-smoothing, min(smoothing, targetMono - monoMix))
        swapMix += max(-smoothing, min(smoothing, targetSwap - swapMix))
        let peak = max(abs(samples.left), channels > 1 ? abs(samples.right) : 0)
        envelope += (peak - envelope) * (peak > envelope ? attack : release)
        let threshold: Float = mode == 1 ? 0.3 : (mode == 3 ? 0.1 : 0.15)
        let ratio: Float = mode == 1 ? 2 : (mode == 3 ? 6 : 4)
        let target: Float = mode == 0 || envelope <= threshold ? 1
            : pow(envelope / threshold, 1 / ratio - 1)
        compressionGain += (target - compressionGain) * (target < compressionGain ? attack : release)
        // 信号低于 -50 dBFS 时不作补偿；上升区渐进，避免抬高静音底噪。
        let signalWeight = max(0, min(1, (envelope - 0.00316) / 0.0285))
        let maxMakeup: Float = mode == 1 ? 1.25 : (mode == 2 ? 1.5 : (mode == 3 ? 1.3 : 1))
        let desiredMakeup = 1 + (maxMakeup - 1) * signalWeight
        makeupGain += (desiredMakeup - makeupGain) * release
        samples.left *= compressionGain * makeupGain
        if channels > 1 {
            samples.right *= compressionGain * makeupGain
            let originalLeft = samples.left
            let originalRight = samples.right
            samples.left += (originalRight - originalLeft) * swapMix
            samples.right += (originalLeft - originalRight) * swapMix
            let mid = (samples.left + samples.right) * 0.5
            samples.left += (mid - samples.left) * monoMix
            samples.right += (mid - samples.right) * monoMix
            samples.left *= 1 - max(0, balance)
            samples.right *= 1 + min(0, balance)
        }
        if wetMix < 1 {
            let clamped = max(0, wetMix)
            samples.left = dryLeft + (samples.left - dryLeft) * clamped
            if channels > 1 {
                samples.right = dryRight + (samples.right - dryRight) * clamped
            }
        }
    }
}
