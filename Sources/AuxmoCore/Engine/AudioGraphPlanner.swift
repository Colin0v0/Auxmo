import CoreAudio
import Foundation

/// 编译音频图所需的完整只读世界状态；不含任何可变副作用。
public struct AudioEngineWorld {
    public var excludedPID: Int32
    public var captureAccess: SystemAudioCaptureAccess
    public var routeConfigurationAvailable: Bool
    public var effectConfigurationAvailable: Bool
    public var effectsEnabled: Bool
    public var hasMixerConflict: Bool
    public var globalSafetyMute: Bool
    public var metersVisible: Bool
    public var routingPolicy: AudioRouteRoutingPolicy
    public var audioSnapshot: SystemAudioSnapshot?
    public var confirmedRoute: ConfirmedOutputRoute?
    public var multiOutputRoute: MultiOutputRoute?
    public var routingBusy: Bool
    public var routingFailed: Bool
    public var configuredMemberUIDs: [String]
    public var unavailableMemberUIDs: Set<String>
    public var processReadError: String?
    public var applications: [ApplicationAudioRow]
    public var mixStates: [String: ApplicationMixState]
    public var storedRoutes: [String: AppAudioRoute]
    public var effectiveEffects: [String: AppAudioEffectSettings]
    public var existingSessionModes: [String: ApplicationAudioMode]
    public var cleanupErrorIDs: Set<String>

    public init(excludedPID: Int32 = getpid(),
                captureAccess: SystemAudioCaptureAccess = .authorized,
                routeConfigurationAvailable: Bool = true,
                effectConfigurationAvailable: Bool = true,
                effectsEnabled: Bool = false,
                hasMixerConflict: Bool = false,
                globalSafetyMute: Bool = false,
                metersVisible: Bool = false,
                routingPolicy: AudioRouteRoutingPolicy = .authorizedGroupOnly,
                audioSnapshot: SystemAudioSnapshot? = nil,
                confirmedRoute: ConfirmedOutputRoute? = nil,
                multiOutputRoute: MultiOutputRoute? = nil,
                routingBusy: Bool = false,
                routingFailed: Bool = false,
                configuredMemberUIDs: [String] = [],
                unavailableMemberUIDs: Set<String> = [],
                processReadError: String? = nil,
                applications: [ApplicationAudioRow] = [],
                mixStates: [String: ApplicationMixState] = [:],
                storedRoutes: [String: AppAudioRoute] = [:],
                effectiveEffects: [String: AppAudioEffectSettings] = [:],
                existingSessionModes: [String: ApplicationAudioMode] = [:],
                cleanupErrorIDs: Set<String> = []) {
        self.excludedPID = excludedPID
        self.captureAccess = captureAccess
        self.routeConfigurationAvailable = routeConfigurationAvailable
        self.effectConfigurationAvailable = effectConfigurationAvailable
        self.effectsEnabled = effectsEnabled
        self.hasMixerConflict = hasMixerConflict
        self.globalSafetyMute = globalSafetyMute
        self.metersVisible = metersVisible
        self.routingPolicy = routingPolicy
        self.audioSnapshot = audioSnapshot
        self.confirmedRoute = confirmedRoute
        self.multiOutputRoute = multiOutputRoute
        self.routingBusy = routingBusy
        self.routingFailed = routingFailed
        self.configuredMemberUIDs = configuredMemberUIDs
        self.unavailableMemberUIDs = unavailableMemberUIDs
        self.processReadError = processReadError
        self.applications = applications
        self.mixStates = mixStates
        self.storedRoutes = storedRoutes
        self.effectiveEffects = effectiveEffects
        self.existingSessionModes = existingSessionModes
        self.cleanupErrorIDs = cleanupErrorIDs
    }
}

/// 纯函数式音频拓扑编译器：将用户意图与硬件事实编译为确定性的 Source → Node → Sink 计划与路由解释。
public enum AudioGraphPlanner {
    /// 硬性剔除 Auxmo 自身进程，防止引擎重放的声音再次被 Process Tap 截获形成正反馈啸叫。
    public static func sanitizeGroup(_ group: AudioProcessGroup, excludedPID: Int32) -> AudioProcessGroup? {
        guard excludedPID > 0, group.processIDs.contains(excludedPID) else {
            return group.objectIDs.isEmpty ? nil : group
        }
        if group.processIDs.count == group.objectIDs.count {
            var filteredPIDs: [Int32] = []
            var filteredObjects: [AudioObjectID] = []
            for (pid, obj) in zip(group.processIDs, group.objectIDs) where pid != excludedPID {
                filteredPIDs.append(pid)
                filteredObjects.append(obj)
            }
            guard !filteredObjects.isEmpty else { return nil }
            return AudioProcessGroup(id: group.id, bundleID: group.bundleID,
                                     processIDs: filteredPIDs, objectIDs: filteredObjects)
        }
        let remainingPIDs = group.processIDs.filter { $0 != excludedPID }
        guard !remainingPIDs.isEmpty, !group.objectIDs.isEmpty else { return nil }
        return AudioProcessGroup(id: group.id, bundleID: group.bundleID,
                                 processIDs: remainingPIDs, objectIDs: group.objectIDs)
    }

    public static func compile(_ world: AudioEngineWorld) -> AudioGraphPlan {
        var sources: [String: PlannedSourceNode] = [:]
        var explanations: [String: AudioRouteExplanation] = [:]
        var edges: [PlannedRouteEdge] = []
        var sinkSources: [String: [String]] = [:]

        let physicalOutputs: [AudioOutput] = (world.audioSnapshot?.outputs ?? [])
            .filter { !$0.isAggregate && $0.supportsSimultaneousOutput && !world.unavailableMemberUIDs.contains($0.uid) }
        let physicalByUID = Dictionary(uniqueKeysWithValues: physicalOutputs.map { ($0.uid, $0) })

        let defaultSinkUIDs = resolveDefaultSinkUIDs(world: world, physicalByUID: physicalByUID)

        for app in world.applications {
            let state = world.mixStates[app.id] ?? ApplicationMixState()
            let storageKey = app.bundleID.isEmpty ? nil : "bundle:\(app.bundleID)"
            let storedRoute: AppAudioRoute = storageKey.flatMap { world.storedRoutes[$0] } ?? .allOutputs
            let effect = storageKey.flatMap { world.effectiveEffects[$0] }
            let effectiveMuted = state.effectiveMuted(globalSafetyMute: world.globalSafetyMute)
            let rule = resolveRule(stored: storedRoute, world: world)
            let sanitizedGroup = app.group.flatMap { sanitizeGroup($0, excludedPID: world.excludedPID) }

            if world.cleanupErrorIDs.contains(app.id) {
                explanations[app.id] = AudioRouteExplanation(
                    applicationID: app.id,
                    bundleID: app.bundleID,
                    disposition: .latchedFailure,
                    rule: rule,
                    sourceTapDeviceUID: nil,
                    requestedSinkUIDs: storedRoute.customDeviceUIDs.sorted(),
                    activeSinkUIDs: [],
                    unavailableSinkUIDs: [],
                    activeNodes: world.existingSessionModes[app.id] == .mixing ? [.sourceTap] : [],
                    effectiveGain: state.gain,
                    effectivelyMuted: true,
                    summary: "旧音频资源尚未完成释放，保留安全静音状态等待重试"
                )
                continue
            }

            guard world.routeConfigurationAvailable else {
                explanations[app.id] = AudioRouteExplanation(
                    applicationID: app.id,
                    bundleID: app.bundleID,
                    disposition: .blockedConfiguration,
                    rule: rule,
                    sourceTapDeviceUID: nil,
                    requestedSinkUIDs: [],
                    activeSinkUIDs: [],
                    unavailableSinkUIDs: [],
                    activeNodes: world.existingSessionModes[app.id] == .mixing ? [.sourceTap] : [],
                    effectiveGain: state.gain,
                    effectivelyMuted: true,
                    summary: "应用路由配置不可读，停止新建接管并保留已有静音捕获"
                )
                continue
            }

            guard world.captureAccess.allowsApplicationAudio else {
                explanations[app.id] = AudioRouteExplanation(
                    applicationID: app.id,
                    bundleID: app.bundleID,
                    disposition: .blockedPermission,
                    rule: rule,
                    sourceTapDeviceUID: nil,
                    requestedSinkUIDs: storedRoute.customDeviceUIDs.sorted(),
                    activeSinkUIDs: [],
                    unavailableSinkUIDs: [],
                    activeNodes: [],
                    effectiveGain: state.gain,
                    effectivelyMuted: effectiveMuted,
                    summary: "系统音频录制尚未授权，无法建立应用独立音频链路"
                )
                continue
            }

            guard world.audioSnapshot != nil,
                  !world.routingBusy,
                  !world.routingFailed,
                  let confirmed = world.confirmedRoute,
                  world.processReadError == nil else {
                explanations[app.id] = AudioRouteExplanation(
                    applicationID: app.id,
                    bundleID: app.bundleID,
                    disposition: .suspendedTransition,
                    rule: rule,
                    sourceTapDeviceUID: nil,
                    requestedSinkUIDs: storedRoute.customDeviceUIDs.sorted(),
                    activeSinkUIDs: [],
                    unavailableSinkUIDs: [],
                    activeNodes: world.existingSessionModes[app.id] == .mixing ? [.sourceTap] : [],
                    effectiveGain: state.gain,
                    effectivelyMuted: true,
                    summary: "系统路由切换中或音频观察未收敛，暂时解绑重放端并保留静音捕获"
                )
                continue
            }

            let resolved = resolveAppRoute(stored: storedRoute, world: world, physicalByUID: physicalByUID)
            if resolved.effective.isWaitingForDevices {
                let nodes: [AudioEngineNodeKind] = (sanitizedGroup != nil && state.failure == nil && !world.hasMixerConflict)
                    ? [.sourceTap, .gainMute]
                    : (world.existingSessionModes[app.id] == .mixing ? [.sourceTap] : [])
                if let group = sanitizedGroup, state.failure == nil, !world.hasMixerConflict {
                    let route = ApplicationPlaybackRoute.single(confirmed.output)
                    sources[app.id] = PlannedSourceNode(
                        applicationID: app.id,
                        group: group,
                        mode: .mixing,
                        suspended: true,
                        nominalOutput: confirmed.output,
                        playbackRoute: route,
                        gain: state.gain,
                        muted: effectiveMuted,
                        effect: effect,
                        targetSinkUIDs: [],
                        isPlaying: app.isRunningOutput
                    )
                }
                explanations[app.id] = AudioRouteExplanation(
                    applicationID: app.id,
                    bundleID: app.bundleID,
                    disposition: .pausedWaitingForDevices,
                    rule: rule,
                    sourceTapDeviceUID: nil,
                    requestedSinkUIDs: storedRoute.customDeviceUIDs.sorted(),
                    activeSinkUIDs: [],
                    unavailableSinkUIDs: resolved.unavailableDeviceUIDs.sorted(),
                    activeNodes: nodes,
                    effectiveGain: state.gain,
                    effectivelyMuted: true,
                    summary: "用户指定的目标设备当前离线或不在活动输出范围内，保持来源静音等待恢复"
                )
                continue
            }

            if confirmed.output.isAggregate {
                guard let multi = world.multiOutputRoute,
                      multi.deviceID == confirmed.output.id,
                      multi.uid == confirmed.output.uid else {
                    explanations[app.id] = AudioRouteExplanation(
                        applicationID: app.id,
                        bundleID: app.bundleID,
                        disposition: state.managed ? .latchedFailure : .passthroughSystem,
                        rule: rule,
                        sourceTapDeviceUID: nil,
                        requestedSinkUIDs: storedRoute.customDeviceUIDs.sorted(),
                        activeSinkUIDs: [],
                        unavailableSinkUIDs: [],
                        activeNodes: [],
                        effectiveGain: state.gain,
                        effectivelyMuted: effectiveMuted,
                        summary: "当前系统输出为外部聚合设备，缺少可验证的物理成员信息"
                    )
                    continue
                }
            }

            let requiresRouting = resolved.effective.isCustom
            let requiresEffects = effect != nil
            let requiresSafetyMute = world.globalSafetyMute
                && (app.isRunningOutput || world.existingSessionModes[app.id] != nil)

            if world.effectsEnabled, !world.effectConfigurationAvailable,
               !state.managed, !requiresRouting,
               world.existingSessionModes[app.id] == .mixing {
                explanations[app.id] = AudioRouteExplanation(
                    applicationID: app.id,
                    bundleID: app.bundleID,
                    disposition: .blockedConfiguration,
                    rule: rule,
                    sourceTapDeviceUID: nil,
                    requestedSinkUIDs: [],
                    activeSinkUIDs: [],
                    unavailableSinkUIDs: [],
                    activeNodes: [.sourceTap],
                    effectiveGain: state.gain,
                    effectivelyMuted: true,
                    summary: "音效配置不可读，保留已有静音捕获等待重新加载"
                )
                continue
            }

            guard let mode = ApplicationAudioIntent.mode(
                state: state,
                isPlaying: app.isRunningOutput,
                meterVisible: world.metersVisible,
                requiresRouting: requiresRouting,
                requiresEffects: requiresEffects,
                requiresSafetyMute: requiresSafetyMute
            ) else {
                if state.failure != nil {
                    explanations[app.id] = AudioRouteExplanation(
                        applicationID: app.id,
                        bundleID: app.bundleID,
                        disposition: .latchedFailure,
                        rule: rule,
                        sourceTapDeviceUID: nil,
                        requestedSinkUIDs: storedRoute.customDeviceUIDs.sorted(),
                        activeSinkUIDs: [],
                        unavailableSinkUIDs: resolved.unavailableDeviceUIDs.sorted(),
                        activeNodes: world.existingSessionModes[app.id] == .mixing ? [.sourceTap] : [],
                        effectiveGain: state.gain,
                        effectivelyMuted: world.existingSessionModes[app.id] == .mixing,
                        summary: state.failure ?? "应用音频链路已暂停，等待重新应用"
                    )
                } else {
                    let passthroughSinks = app.isRunningOutput ? defaultSinkUIDs : []
                    explanations[app.id] = AudioRouteExplanation(
                        applicationID: app.id,
                        bundleID: app.bundleID,
                        disposition: .passthroughSystem,
                        rule: rule,
                        sourceTapDeviceUID: nil,
                        requestedSinkUIDs: [],
                        activeSinkUIDs: passthroughSinks,
                        unavailableSinkUIDs: [],
                        activeNodes: [],
                        effectiveGain: 1,
                        effectivelyMuted: false,
                        summary: passthroughSinks.isEmpty
                            ? "应用当前空闲，未接管音频流"
                            : "未启用应用接管，由系统直接输出至 \(passthroughSinks.joined(separator: ", "))"
                    )
                }
                continue
            }

            if mode == .mixing, state.managed, state.boundOutputUID != confirmed.output.uid {
                explanations[app.id] = AudioRouteExplanation(
                    applicationID: app.id,
                    bundleID: app.bundleID,
                    disposition: .latchedFailure,
                    rule: rule,
                    sourceTapDeviceUID: nil,
                    requestedSinkUIDs: storedRoute.customDeviceUIDs.sorted(),
                    activeSinkUIDs: [],
                    unavailableSinkUIDs: resolved.unavailableDeviceUIDs.sorted(),
                    activeNodes: [],
                    effectiveGain: state.gain,
                    effectivelyMuted: false,
                    summary: ApplicationMixFailure.outputChanged.message
                )
                continue
            }

            guard !world.hasMixerConflict else {
                explanations[app.id] = AudioRouteExplanation(
                    applicationID: app.id,
                    bundleID: app.bundleID,
                    disposition: .blockedConflict,
                    rule: rule,
                    sourceTapDeviceUID: nil,
                    requestedSinkUIDs: storedRoute.customDeviceUIDs.sorted(),
                    activeSinkUIDs: [],
                    unavailableSinkUIDs: resolved.unavailableDeviceUIDs.sorted(),
                    activeNodes: [],
                    effectiveGain: state.gain,
                    effectivelyMuted: false,
                    summary: ApplicationMixFailure.fineTuneRunning.message
                )
                continue
            }

            guard let group = sanitizedGroup else {
                explanations[app.id] = AudioRouteExplanation(
                    applicationID: app.id,
                    bundleID: app.bundleID,
                    disposition: .awaitingProcessStream,
                    rule: rule,
                    sourceTapDeviceUID: nil,
                    requestedSinkUIDs: storedRoute.customDeviceUIDs.sorted(),
                    activeSinkUIDs: [],
                    unavailableSinkUIDs: resolved.unavailableDeviceUIDs.sorted(),
                    activeNodes: [],
                    effectiveGain: state.gain,
                    effectivelyMuted: effectiveMuted,
                    summary: "等待应用注册可捕获的音频流对象"
                )
                continue
            }

            do {
                let playbackRoute = try buildPlaybackRoute(
                    confirmed: confirmed,
                    multiOutputRoute: world.multiOutputRoute,
                    effectiveRoute: resolved.effective,
                    routingPolicy: world.routingPolicy,
                    physicalOutputs: physicalOutputs
                )
                let sinkUIDs: [String]
                if mode == .mixing {
                    sinkUIDs = playbackRoute.playbackDeviceUIDs.filter { physicalByUID[$0] != nil }
                } else {
                    sinkUIDs = []
                }
                sources[app.id] = PlannedSourceNode(
                    applicationID: app.id,
                    group: group,
                    mode: mode,
                    suspended: false,
                    nominalOutput: confirmed.output,
                    playbackRoute: playbackRoute,
                    gain: state.gain,
                    muted: effectiveMuted,
                    effect: mode == .mixing ? effect : nil,
                    targetSinkUIDs: sinkUIDs,
                    isPlaying: app.isRunningOutput
                )
                let activeNodes = AudioEngineNodeKind.activeChain(
                    mode: mode,
                    effect: mode == .mixing ? effect : nil,
                    hasActiveSinks: !sinkUIDs.isEmpty
                )
                if mode == .mixing {
                    for sinkUID in sinkUIDs {
                        edges.append(PlannedRouteEdge(sourceID: app.id, sinkUID: sinkUID))
                        sinkSources[sinkUID, default: []].append(app.id)
                    }
                    explanations[app.id] = AudioRouteExplanation(
                        applicationID: app.id,
                        bundleID: app.bundleID,
                        disposition: .routed,
                        rule: rule,
                        sourceTapDeviceUID: playbackRoute.tapDeviceUID.isEmpty ? nil : playbackRoute.tapDeviceUID,
                        requestedSinkUIDs: storedRoute.customDeviceUIDs.sorted(),
                        activeSinkUIDs: sinkUIDs,
                        unavailableSinkUIDs: resolved.unavailableDeviceUIDs.sorted(),
                        activeNodes: activeNodes,
                        effectiveGain: state.gain,
                        effectivelyMuted: effectiveMuted,
                        summary: sinkUIDs.isEmpty
                            ? "已接管来源静音，当前无在线输出目标"
                            : "经引擎节点链重放至物理设备：\(sinkUIDs.joined(separator: ", "))"
                    )
                } else {
                    let passthroughSinks = app.isRunningOutput ? defaultSinkUIDs : []
                    explanations[app.id] = AudioRouteExplanation(
                        applicationID: app.id,
                        bundleID: app.bundleID,
                        disposition: .meteringOnly,
                        rule: rule,
                        sourceTapDeviceUID: playbackRoute.tapDeviceUID.isEmpty ? nil : playbackRoute.tapDeviceUID,
                        requestedSinkUIDs: [],
                        activeSinkUIDs: passthroughSinks,
                        unavailableSinkUIDs: [],
                        activeNodes: activeNodes,
                        effectiveGain: 1,
                        effectivelyMuted: false,
                        summary: "只读捕获实时电平，原声继续由系统直通输出"
                    )
                }
            } catch {
                explanations[app.id] = AudioRouteExplanation(
                    applicationID: app.id,
                    bundleID: app.bundleID,
                    disposition: .latchedFailure,
                    rule: rule,
                    sourceTapDeviceUID: nil,
                    requestedSinkUIDs: storedRoute.customDeviceUIDs.sorted(),
                    activeSinkUIDs: [],
                    unavailableSinkUIDs: resolved.unavailableDeviceUIDs.sorted(),
                    activeNodes: [],
                    effectiveGain: state.gain,
                    effectivelyMuted: false,
                    summary: error.localizedDescription
                )
            }
        }

        var sinks: [String: PlannedSinkNode] = [:]
        for (uid, incoming) in sinkSources {
            guard let output = physicalByUID[uid] else { continue }
            sinks[uid] = PlannedSinkNode(output: output, incomingSourceIDs: incoming.sorted())
        }

        return AudioGraphPlan(
            sources: sources,
            sinks: sinks,
            edges: edges.sorted { ($0.sourceID, $0.sinkUID) < ($1.sourceID, $1.sinkUID) },
            explanations: explanations
        )
    }

    private static func resolveRule(stored: AppAudioRoute, world: AudioEngineWorld) -> AudioRouteExplanation.RuleSource {
        if world.globalSafetyMute { return .globalSafetyMute }
        if stored.isCustom { return .customSelection }
        if world.confirmedRoute?.intent.isSimultaneous == true { return .followMultiOutputGroup }
        return .followSystemOutput
    }

    private static func resolveDefaultSinkUIDs(world: AudioEngineWorld,
                                               physicalByUID: [String: AudioOutput]) -> [String] {
        guard let snapshot = world.audioSnapshot,
              !world.routingBusy,
              !world.routingFailed,
              let selected = snapshot.outputs.first(where: { $0.id == snapshot.selectedID }) else {
            return []
        }
        if let multi = world.confirmedRoute?.aggregate, multi.uid == selected.uid {
            return multi.outputs.map(\.uid).filter { physicalByUID[$0] != nil }
        }
        if !selected.isAggregate, physicalByUID[selected.uid] != nil {
            return [selected.uid]
        }
        return []
    }

    private static func resolveAppRoute(stored: AppAudioRoute,
                                        world: AudioEngineWorld,
                                        physicalByUID: [String: AudioOutput]) -> ResolvedAppAudioRoute {
        switch world.routingPolicy {
        case .authorizedGroupOnly:
            guard world.confirmedRoute?.intent.isSimultaneous == true else {
                return AppAudioRouteResolver.resolve(stored: stored, configuredDeviceUIDs: [], activeDeviceUIDs: [])
            }
            let configured = world.configuredMemberUIDs.filter { !$0.isEmpty }
            let groupOutputs = world.confirmedRoute?.aggregate?.outputs
                ?? world.confirmedRoute.map { [$0.output] }
                ?? []
            let active = groupOutputs.map(\.uid).filter { physicalByUID[$0] != nil }
            return AppAudioRouteResolver.resolve(stored: stored,
                                                 configuredDeviceUIDs: configured,
                                                 activeDeviceUIDs: active)
        case .independentPhysicalOutputs:
            let allPhysicalUIDs = Array(physicalByUID.keys).sorted()
            return AppAudioRouteResolver.resolve(stored: stored,
                                                 configuredDeviceUIDs: allPhysicalUIDs,
                                                 activeDeviceUIDs: allPhysicalUIDs)
        }
    }

    private static func buildPlaybackRoute(confirmed: ConfirmedOutputRoute,
                                           multiOutputRoute: MultiOutputRoute?,
                                           effectiveRoute: EffectiveAppAudioRoute,
                                           routingPolicy: AudioRouteRoutingPolicy,
                                           physicalOutputs: [AudioOutput]) throws -> ApplicationPlaybackRoute {
        switch routingPolicy {
        case .authorizedGroupOnly:
            if confirmed.output.isAuxmoMultiOutput {
                guard let multi = multiOutputRoute,
                      multi.deviceID == confirmed.output.id,
                      multi.uid == confirmed.output.uid else {
                    throw AudioFailure("Auxmo 多设备输出缺少当前成员信息，请重新配置组合")
                }
                let targets: [AudioOutput]
                switch effectiveRoute {
                case .custom(let uids):
                    targets = multi.outputs.filter { uids.contains($0.uid) }
                    guard !targets.isEmpty else {
                        throw AudioFailure("应用自定义路由的所选设备当前不可用")
                    }
                case .allOutputs:
                    targets = multi.outputs
                case .waitingForDevices:
                    throw AudioFailure("所选输出不可用，已暂停播放")
                case .configurationUnavailable:
                    throw AudioFailure("应用路由配置不可用")
                }
                return try ApplicationPlaybackRoute(output: confirmed.output,
                                                    playbackOutputs: targets,
                                                    groupOutputs: multi.outputs,
                                                    mainOutputUID: multi.mainOutputUID)
            }
            return .single(confirmed.output)

        case .independentPhysicalOutputs:
            switch effectiveRoute {
            case .custom(let uids):
                let targets = physicalOutputs.filter { uids.contains($0.uid) }
                guard !targets.isEmpty else {
                    throw AudioFailure("应用自定义路由的所选设备当前不可用")
                }
                let sourceDevice: AudioOutput?
                if let multi = multiOutputRoute, multi.uid == confirmed.output.uid {
                    sourceDevice = multi.outputs.first { $0.uid == multi.mainOutputUID } ?? multi.outputs.first
                } else {
                    sourceDevice = confirmed.output
                }
                return try ApplicationPlaybackRoute(independentSource: sourceDevice,
                                                    playbackOutputs: targets)
            case .allOutputs:
                if confirmed.output.isAuxmoMultiOutput, let multi = multiOutputRoute {
                    return try ApplicationPlaybackRoute(output: confirmed.output,
                                                        playbackOutputs: multi.outputs,
                                                        groupOutputs: multi.outputs,
                                                        mainOutputUID: multi.mainOutputUID)
                }
                return .single(confirmed.output)
            case .waitingForDevices:
                throw AudioFailure("所选输出不可用，已暂停播放")
            case .configurationUnavailable:
                throw AudioFailure("应用路由配置不可用")
            }
        }
    }
}
