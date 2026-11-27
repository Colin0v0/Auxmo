import CoreAudio
import Foundation

/// 音频图中的标准处理节点类型，用于状态展示、因果解释与诊断报告。
public enum AudioEngineNodeKind: String, Codable, Equatable, Sendable {
    case sourceTap
    case gainMute
    case equalizer
    case spatial
    case dynamics
    case channel
    case meterProbe
    case routeCrossfade
    case sinkSummingBus
    case sinkSafetyLimiter

    public static func activeChain(mode: ApplicationAudioMode,
                                   effect: AppAudioEffectSettings?,
                                   hasActiveSinks: Bool) -> [Self] {
        var nodes: [Self] = [.sourceTap]
        if mode == .mixing {
            nodes.append(.gainMute)
            if let effect, effect.enabled {
                let hasEQ = (0..<AppAudioEffectEQ.bandCount).contains { effect.eq[$0] != 0 }
                if hasEQ { nodes.append(.equalizer) }
                if effect.spatial.mode.isEnabled { nodes.append(.spatial) }
                if effect.dynamics != .off { nodes.append(.dynamics) }
                if effect.channel.balance != 0 || effect.channel.mono || effect.channel.swap {
                    nodes.append(.channel)
                }
            }
        }
        nodes.append(.meterProbe)
        if mode == .mixing, hasActiveSinks {
            nodes.append(contentsOf: [.routeCrossfade, .sinkSummingBus, .sinkSafetyLimiter])
        }
        return nodes
    }
}

/// 应用路由解析策略：默认严格受已确认输出组约束；引擎亦原生支持跨任意在线物理设备直接分发。
public enum AudioRouteRoutingPolicy: String, Codable, Equatable, Sendable {
    case authorizedGroupOnly
    case independentPhysicalOutputs
}

/// 解释某个 App 当前音频为何走向特定物理设备，或为何处于静音保持/等待状态。
public struct AudioRouteExplanation: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Equatable, Sendable {
        case passthroughSystem
        case meteringOnly
        case routed
        case pausedWaitingForDevices
        case suspendedTransition
        case awaitingProcessStream
        case blockedPermission
        case blockedConfiguration
        case blockedConflict
        case latchedFailure
    }

    public enum RuleSource: String, Codable, Equatable, Sendable {
        case followSystemOutput
        case followMultiOutputGroup
        case customSelection
        case globalSafetyMute
    }

    public let applicationID: String
    public let bundleID: String
    public let disposition: Disposition
    public let rule: RuleSource
    public let sourceTapDeviceUID: String?
    public let requestedSinkUIDs: [String]
    public let activeSinkUIDs: [String]
    public let unavailableSinkUIDs: [String]
    public let activeNodes: [AudioEngineNodeKind]
    public let effectiveGain: Float
    public let effectivelyMuted: Bool
    public let summary: String

    public init(applicationID: String,
                bundleID: String,
                disposition: Disposition,
                rule: RuleSource,
                sourceTapDeviceUID: String?,
                requestedSinkUIDs: [String],
                activeSinkUIDs: [String],
                unavailableSinkUIDs: [String],
                activeNodes: [AudioEngineNodeKind],
                effectiveGain: Float,
                effectivelyMuted: Bool,
                summary: String) {
        self.applicationID = applicationID
        self.bundleID = bundleID
        self.disposition = disposition
        self.rule = rule
        self.sourceTapDeviceUID = sourceTapDeviceUID
        self.requestedSinkUIDs = requestedSinkUIDs
        self.activeSinkUIDs = activeSinkUIDs
        self.unavailableSinkUIDs = unavailableSinkUIDs
        self.activeNodes = activeNodes
        self.effectiveGain = effectiveGain
        self.effectivelyMuted = effectivelyMuted
        self.summary = summary
    }
}

/// 图规划器产出的单个 App Source 节点目标状态。
public struct PlannedSourceNode: Equatable, Sendable {
    public let applicationID: String
    public let group: AudioProcessGroup
    public let mode: ApplicationAudioMode
    public let suspended: Bool
    public let nominalOutput: AudioOutput
    public let playbackRoute: ApplicationPlaybackRoute
    public let gain: Float
    public let muted: Bool
    public let effect: AppAudioEffectSettings?
    public let targetSinkUIDs: [String]
    public let isPlaying: Bool

    public init(applicationID: String,
                group: AudioProcessGroup,
                mode: ApplicationAudioMode,
                suspended: Bool,
                nominalOutput: AudioOutput,
                playbackRoute: ApplicationPlaybackRoute,
                gain: Float,
                muted: Bool,
                effect: AppAudioEffectSettings?,
                targetSinkUIDs: [String],
                isPlaying: Bool) {
        self.applicationID = applicationID
        self.group = group
        self.mode = mode
        self.suspended = suspended
        self.nominalOutput = nominalOutput
        self.playbackRoute = playbackRoute
        self.gain = gain
        self.muted = muted
        self.effect = effect
        self.targetSinkUIDs = targetSinkUIDs
        self.isPlaying = isPlaying
    }
}

/// 图规划器产出的单个物理输出设备 Sink 节点目标状态。
public struct PlannedSinkNode: Equatable, Sendable {
    public let output: AudioOutput
    public let incomingSourceIDs: [String]

    public init(output: AudioOutput, incomingSourceIDs: [String]) {
        self.output = output
        self.incomingSourceIDs = incomingSourceIDs
    }
}

/// 从 App Source 指向物理设备 Sink 的有向音频分发边。
public struct PlannedRouteEdge: Equatable, Sendable {
    public let sourceID: String
    public let sinkUID: String

    public init(sourceID: String, sinkUID: String) {
        self.sourceID = sourceID
        self.sinkUID = sinkUID
    }
}

/// 一次完整音频图编译产出的不可变拓扑计划。
public struct AudioGraphPlan: Equatable, Sendable {
    public static let empty = AudioGraphPlan(sources: [:], sinks: [:], edges: [], explanations: [:])

    public let sources: [String: PlannedSourceNode]
    public let sinks: [String: PlannedSinkNode]
    public let edges: [PlannedRouteEdge]
    public let explanations: [String: AudioRouteExplanation]

    public init(sources: [String: PlannedSourceNode],
                sinks: [String: PlannedSinkNode],
                edges: [PlannedRouteEdge],
                explanations: [String: AudioRouteExplanation]) {
        self.sources = sources
        self.sinks = sinks
        self.edges = edges
        self.explanations = explanations
    }

    /// 返回某个正在发声的 App 当前真实送达的物理输出设备集合（供统计与状态展示消费）。
    public func activeOutputs(for applicationID: String, onlineOutputs: [AudioOutput]) -> [AudioOutput] {
        guard let explanation = explanations[applicationID] else { return [] }
        switch explanation.disposition {
        case .routed, .passthroughSystem, .meteringOnly:
            let uids = Set(explanation.activeSinkUIDs)
            guard !uids.isEmpty else { return [] }
            return onlineOutputs.filter { !$0.isAggregate && uids.contains($0.uid) }
        case .pausedWaitingForDevices, .suspendedTransition, .awaitingProcessStream,
             .blockedPermission, .blockedConfiguration, .blockedConflict, .latchedFailure:
            return []
        }
    }
}

/// 单个物理设备 Sink 的只读所有权诊断快照（不读取 HAL，不包含样本内容）。
public struct AudioSinkResourceSnapshot: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case absent
        case registered
        case running
    }

    public let deviceID: AudioDeviceID
    public let uid: String
    public let name: String
    public let stage: Stage
    public let sampleRate: Double?
    public let activeSourceIDs: [String]
    public let fadingOutSourceIDs: [String]
    public let replayEnabled: Bool

    public init(deviceID: AudioDeviceID,
                uid: String,
                name: String,
                stage: Stage,
                sampleRate: Double?,
                activeSourceIDs: [String],
                fadingOutSourceIDs: [String],
                replayEnabled: Bool) {
        self.deviceID = deviceID
        self.uid = uid
        self.name = name
        self.stage = stage
        self.sampleRate = sampleRate
        self.activeSourceIDs = activeSourceIDs
        self.fadingOutSourceIDs = fadingOutSourceIDs
        self.replayEnabled = replayEnabled
    }
}

/// AuxmoAudioEngine 的整体只读诊断快照。
public struct AudioEngineDiagnosticSnapshot: Codable, Equatable, Sendable {
    public let activeSourceCount: Int
    public let activeSinkCount: Int
    public let activeEdgeCount: Int
    public let sinks: [AudioSinkResourceSnapshot]
    public let explanations: [AudioRouteExplanation]

    public init(activeSourceCount: Int,
                activeSinkCount: Int,
                activeEdgeCount: Int,
                sinks: [AudioSinkResourceSnapshot],
                explanations: [AudioRouteExplanation]) {
        self.activeSourceCount = activeSourceCount
        self.activeSinkCount = activeSinkCount
        self.activeEdgeCount = activeEdgeCount
        self.sinks = sinks
        self.explanations = explanations
    }
}
