import Foundation

/// 会话只有在已确认的路由上创建。测试注入等价接口，不创建真实 tap、不修改系统输出。
@MainActor
public protocol ApplicationAudioSession: AnyObject {
    var group: AudioProcessGroup { get }
    var output: AudioOutput { get }
    var mode: ApplicationAudioMode { get }
    /// 会话实际使用的捕获源与重放目标；模型据此判断是否需要因设备集合变化重建。
    var playbackRoute: ApplicationPlaybackRoute { get }
    var isActive: Bool { get }
    var isReleased: Bool { get }
    var isSuspendedForOutputChange: Bool { get }
    /// 引擎化会话的捕获源与物理输出解耦，可以在设备切换期间保持捕获回调运行。
    var supportsContinuousOutputSwitch: Bool { get }
    func setGain(_ value: Float) throws
    func setMuted(_ value: Bool)
    /// 只读计量会话没有重放增益可调；全局安全静音直接切换它的 tap 来源静音行为。
    func setSafetyMute(_ value: Bool) throws
    /// 音效参数通过会话拥有的原子槽下发；不重建 tap，也不在音频线程同步界面状态。
    func setEffect(_ settings: AppAudioEffectSettings?)
    /// 输出路由切换前保留 tap 并解除设备绑定，让静音覆盖过渡期。
    func suspendForOutputChange() throws
    /// 同一应用的输出目标变化时保留现有 tap，只重建重放聚合，避免捕获静音出现空档。
    func switchOutput(to output: AudioOutput, playbackRoute: ApplicationPlaybackRoute) throws
    /// 只建立无设备绑定的静音 tap，不创建重放聚合或 I/O 回调。
    func startSuspended() throws
    /// 同一应用的进程变化时更新同一 tap，避免 stop/start 暴露原声。
    func updateProcesses(to group: AudioProcessGroup) throws
    func start() throws
    func checkHealth(expectingAudio: Bool) throws
    func stop() throws
    func consumePeak() -> Float?
}

/// 路由尚未传播，或同一蓝牙设备正在改变原生 PCM 格式，都不是权限失败。
/// 调用层按截止时间等待同一目标，并按真实格式重建同一处理链。
public struct ApplicationRoutePending: Error {
    public enum Reason: Sendable { case routePropagation, formatChange }
    public let reason: Reason
    public let detail: String?
    public init(reason: Reason = .routePropagation, detail: String? = nil) {
        self.reason = reason
        self.detail = detail
    }
}
