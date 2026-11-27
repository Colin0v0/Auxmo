import AppKit
import CoreAudio
import Foundation
import UniformTypeIdentifiers
import AuxmoCore

/// 诊断事件只保存在内存里，导出时再写入文件；不记录音频样本、文件内容或密码。
struct AuxmoDiagnosticEvent: Codable, Equatable {
    let timestamp: String
    let category: String
    let message: String
}

/// 有限长度的内存事件缓冲；同一错误在短时间内重复出现时只保留第一条。
/// 音频回调线程不直接写这里，所有调用都发生在主线程状态更新之后。
@MainActor
final class DiagnosticEventLog {
    private let capacity: Int
    private let dedupeWindow: TimeInterval
    private let now: () -> Date
    private var events: [AuxmoDiagnosticEvent] = []
    private var lastRecordedAt: [String: Date] = [:]

    init(capacity: Int = 300,
         dedupeWindow: TimeInterval = 2,
         now: @escaping () -> Date = Date.init) {
        precondition(capacity > 0, "诊断事件缓冲必须保留至少一条记录")
        self.capacity = capacity
        self.dedupeWindow = dedupeWindow
        self.now = now
    }

    func record(category: String, message: String, at date: Date? = nil) {
        let timestamp = date ?? now()
        // 去重窗口之外的时间戳已经无效，顺带清理可以避免长期运行时映射无限增长。
        lastRecordedAt = lastRecordedAt.filter {
            timestamp.timeIntervalSince($0.value) < dedupeWindow
        }
        let key = "\(category)\u{0}\(message)"
        if let last = lastRecordedAt[key],
           timestamp.timeIntervalSince(last) < dedupeWindow {
            return
        }
        lastRecordedAt[key] = timestamp
        events.append(AuxmoDiagnosticEvent(
            timestamp: DiagnosticTimestamp.iso8601(timestamp),
            category: category,
            message: message
        ))
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    func snapshot() -> [AuxmoDiagnosticEvent] {
        events
    }

    /// 只用于验证去重映射不会随运行时间无限增长。
    var dedupeKeyCount: Int { lastRecordedAt.count }
}

struct AuxmoDiagnosticReport: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: String
    let privacy: String
    let app: DiagnosticAppInfo
    let system: DiagnosticSystemInfo
    let audio: DiagnosticAudioState
    let routing: DiagnosticRoutingState
    let engine: AudioEngineDiagnosticSnapshot
    let applications: [DiagnosticApplicationState]
    let storedApplicationRoutes: [DiagnosticStoredRoute]
    let errors: DiagnosticErrorState
    let headphones: [DiagnosticHeadphoneState]
    let recentEvents: [AuxmoDiagnosticEvent]
}

struct DiagnosticAppInfo: Codable, Equatable {
    let version: String
    let build: String
    let bundleIdentifier: String
    let processID: Int32
}

struct DiagnosticSystemInfo: Codable, Equatable {
    let macOSVersion: String
    let architecture: String
}

struct DiagnosticAudioState: Codable, Equatable {
    let mediaOutputDeviceID: UInt32?
    let systemOutputDeviceID: UInt32?
    let selectedInputDeviceID: UInt32?
    let outputs: [DiagnosticDeviceState]
    let inputs: [DiagnosticDeviceState]
    let audioReadError: String?
    let inputReadError: String?
    let captureAccess: String
}

struct DiagnosticDeviceState: Codable, Equatable {
    let id: UInt32
    let uid: String
    let name: String
    let direction: String
    let transport: UInt32
    let isBluetooth: Bool
    let isAggregate: Bool
    let isAuxmoMultiOutput: Bool
    let isSelectedMediaOutput: Bool
    let isSelectedSystemOutput: Bool
    let isSelectedInput: Bool
    let control: DiagnosticDeviceControlState
}

struct DiagnosticDeviceControlState: Codable, Equatable {
    /// available、failed、notRead 分开表示，不能用零音量或未静音冒充读取失败。
    let state: String
    let volume: Float?
    let volumeWritable: Bool?
    let muted: Bool?
    let muteWritable: Bool?
    let error: String?
}

struct DiagnosticRoutingState: Codable, Equatable {
    let phase: String
    let desiredMembers: [String]
    let configuredMembers: [String]
    let unavailableMemberUIDs: [String]
    let confirmedIntentMembers: [String]
    let confirmedOutput: DiagnosticDeviceRef?
    let actualOutput: DiagnosticDeviceRef?
    let actualSystemOutputDeviceID: UInt32?
    let pendingCleanup: [DiagnosticDeviceRef]
    let completedSteps: [String]
    let error: String?
    let warning: String?
    let aggregate: DiagnosticAggregateState?
}

struct DiagnosticAggregateState: Codable, Equatable {
    let deviceID: UInt32
    let uid: String
    let outputs: [DiagnosticDeviceRef]
    let mainOutputUID: String
    let previousOutputUID: String
    let sampleRate: Double
}

struct DiagnosticDeviceRef: Codable, Equatable {
    let id: UInt32
    let uid: String
    let name: String
}

struct DiagnosticMixState: Codable, Equatable {
    let gain: Float
    let muted: Bool
    let managed: Bool
    let boundOutputUID: String?
    let failure: String?
}

struct DiagnosticApplicationSessionState: Codable, Equatable {
    let resources: AudioSessionResourceSnapshot?
    let mode: String
    let output: DiagnosticDeviceRef
    let sourceOutputUID: String
    let tapDeviceUID: String
    let playbackDeviceUIDs: [String]
    let mainDeviceUID: String
    let isStacked: Bool
    let isActive: Bool
    let isReleased: Bool
    let isSuspendedForOutputChange: Bool
}

struct DiagnosticApplicationRoute: Codable, Equatable {
    let storageKey: String?
    let stored: String
    let storedDeviceUIDs: [String]
    let resolved: String
    let resolvedDeviceUIDs: [String]
    let effective: String
    let effectiveDeviceUIDs: [String]
}

struct DiagnosticApplicationState: Codable, Equatable {
    let id: String
    let bundleID: String
    let name: String?
    let isPlaying: Bool
    let processIDs: [Int32]
    let audioObjectIDs: [UInt32]
    let mix: DiagnosticMixState?
    let route: DiagnosticApplicationRoute
    let routeExplanation: AudioRouteExplanation?
    let storedEffect: AppAudioEffectSettings?
    let effectConfigurationAvailable: Bool?
    let effectPresetsAvailable: Bool?
    let session: DiagnosticApplicationSessionState?
}

struct DiagnosticStoredRoute: Codable, Equatable {
    let storageKey: String
    let stored: String
    let deviceUIDs: [String]
}

struct DiagnosticErrorState: Codable, Equatable {
    let audio: String?
    let input: String?
    let inputOperation: String?
    let process: String?
    let operation: String?
    let appAudioRoutePersistence: String?
    let appAudioEffectPersistence: String?
    let cleanup: [String: String]
}

struct DiagnosticHeadphoneState: Codable, Equatable {
    let name: String
    let outputUID: String
    let phase: String
    let family: String?
    let error: String?
    let boundOutputUID: String?
    let diagnosticLines: [String]
}

enum DiagnosticTimestamp {
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func filename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Auxmo-Diagnostics-\(formatter.string(from: date)).json"
    }
}

/// 诊断报告只做本地编码和写盘；若系统拒绝保存或磁盘写入失败，调用方必须显示明确错误。
enum AuxmoDiagnosticExporter {
    static func data(for report: AuxmoDiagnosticReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    @MainActor
    static func save(_ report: AuxmoDiagnosticReport) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = DiagnosticTimestamp.filename(Date())
        panel.title = AppSettings.shared.localized("导出 Auxmo 诊断报告")
        panel.message = AppSettings.shared.localized("报告包含当前音频状态和近期错误，不包含音频内容。")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data(for: report).write(to: url, options: .atomic)
        return url
    }

}

extension AppModel {
    /// 快照从当前已发布状态构建，不在导出时主动重放或切换任何音频资源。
    func makeDiagnosticReport(generatedAt: Date = Date()) -> AuxmoDiagnosticReport {
        refreshAudioGraphPlan()
        diagnosticEventLog.record(category: "diagnostics", message: "report requested", at: generatedAt)
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        let mediaOutputID: AudioDeviceID? = audio.flatMap {
            $0.selectedID == 0 ? nil : $0.selectedID
        }
        let systemOutputID = outputRouting.actualSystemOutputID
        let audioDevices = audio?.outputs.map { output in
            diagnosticOutput(output, snapshot: audio, systemOutputID: systemOutputID)
        } ?? []
        let inputDevices = inputAudio?.inputs.map { input in
            diagnosticInput(input, snapshot: inputAudio)
        } ?? []
        let applicationStates = applications.map { app in
            diagnosticApplication(app)
        }
        let storedRoutes = appAudioRoutes.keys.sorted().map { key in
            let route = appAudioRoutes[key] ?? .allOutputs
            return DiagnosticStoredRoute(
                storageKey: key,
                stored: route.diagnosticDescription,
                deviceUIDs: route.customDeviceUIDs.sorted()
            )
        }
        let headphoneStates = headphones.entries.map { entry in
            DiagnosticHeadphoneState(
                name: entry.output.name,
                outputUID: entry.output.uid,
                phase: entry.controller.phase.title,
                family: entry.controller.family?.rawValue,
                error: entry.controller.errorMessage,
                boundOutputUID: entry.controller.boundOutputUID,
                diagnosticLines: entry.controller.diagnosticLines
            )
        }
        return AuxmoDiagnosticReport(
            schemaVersion: 1,
            generatedAt: DiagnosticTimestamp.iso8601(generatedAt),
            privacy: "仅包含音频设备、路由、应用会话和错误元数据；不包含音频样本、文件内容、密码或令牌。",
            app: DiagnosticAppInfo(
                version: AuxmoVersion.current,
                build: build,
                bundleIdentifier: bundleIdentifier,
                processID: getpid()
            ),
            system: DiagnosticSystemInfo(
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: DiagnosticSystemInfo.architecture
            ),
            audio: DiagnosticAudioState(
                mediaOutputDeviceID: mediaOutputID,
                systemOutputDeviceID: systemOutputID,
                selectedInputDeviceID: inputAudio?.selectedID,
                outputs: audioDevices,
                inputs: inputDevices,
                audioReadError: audioError,
                inputReadError: inputError,
                captureAccess: audioCaptureAccess.diagnosticDescription
            ),
            routing: diagnosticRouting(outputRouting),
            engine: audioEngine.diagnosticSnapshot,
            applications: applicationStates,
            storedApplicationRoutes: storedRoutes,
            errors: DiagnosticErrorState(
                audio: audioError,
                input: inputError,
                inputOperation: inputOperationError,
                process: processError,
                operation: operationError,
                appAudioRoutePersistence: appAudioRoutePersistenceError,
                appAudioEffectPersistence: appAudioEffectPersistenceError,
                cleanup: cleanupErrors
            ),
            headphones: headphoneStates,
            recentEvents: diagnosticEventLog.snapshot()
        )
    }

    private func diagnosticOutput(_ output: AudioOutput,
                                  snapshot: SystemAudioSnapshot?,
                                  systemOutputID: AudioDeviceID?) -> DiagnosticDeviceState {
        DiagnosticDeviceState(
            id: output.id,
            uid: output.uid,
            name: output.name,
            direction: "output",
            transport: output.transport,
            isBluetooth: output.isBluetooth,
            isAggregate: output.isAggregate,
            isAuxmoMultiOutput: output.isAuxmoMultiOutput,
            isSelectedMediaOutput: snapshot?.selectedID == output.id,
            isSelectedSystemOutput: systemOutputID == output.id,
            isSelectedInput: false,
            control: DiagnosticDeviceControlState(snapshot?.controls[output.id])
        )
    }

    private func diagnosticInput(_ input: AudioInput,
                                 snapshot: SystemInputSnapshot?) -> DiagnosticDeviceState {
        DiagnosticDeviceState(
            id: input.id,
            uid: input.uid,
            name: input.name,
            direction: "input",
            transport: input.transport,
            isBluetooth: input.transport == kAudioDeviceTransportTypeBluetooth
                || input.transport == kAudioDeviceTransportTypeBluetoothLE,
            isAggregate: false,
            isAuxmoMultiOutput: false,
            isSelectedMediaOutput: false,
            isSelectedSystemOutput: false,
            isSelectedInput: snapshot?.selectedID == input.id,
            control: DiagnosticDeviceControlState(snapshot?.controls[input.id])
        )
    }

    private func diagnosticApplication(_ app: ApplicationAudioRow) -> DiagnosticApplicationState {
        let storageKey = applicationRouteStorageKeyForDiagnostics(app)
        let storedRoute = applicationRouteConfigurationAvailable ? storageKey.flatMap { appAudioRoutes[$0] } : nil
        let resolvedRoute = applicationAudioRoute(for: app.id)
        let effectiveRoute = effectiveApplicationAudioRoute(for: app.id)
        let session = sessions[app.id]
        return DiagnosticApplicationState(
            id: app.id,
            bundleID: app.bundleID,
            name: app.name,
            isPlaying: app.isRunningOutput,
            processIDs: app.group?.processIDs ?? [],
            audioObjectIDs: app.group?.objectIDs ?? [],
            mix: mixStates[app.id].map {
                DiagnosticMixState(gain: $0.gain, muted: $0.muted, managed: $0.managed,
                                   boundOutputUID: $0.boundOutputUID,
                                   failure: $0.failure)
            },
            route: DiagnosticApplicationRoute(
                storageKey: storageKey,
                stored: applicationRouteConfigurationAvailable ? (storedRoute?.diagnosticDescription ?? "absent") : "configurationUnavailable",
                storedDeviceUIDs: storedRoute?.customDeviceUIDs.sorted() ?? [],
                resolved: resolvedRoute?.diagnosticDescription ?? "configurationUnavailable",
                resolvedDeviceUIDs: resolvedRoute?.customDeviceUIDs.sorted() ?? [],
                effective: effectiveRoute.diagnosticDescription,
                effectiveDeviceUIDs: effectiveRoute.customDeviceUIDs.sorted()
            ),
            routeExplanation: routeExplanation(for: app.id),
            storedEffect: storageKey.flatMap { appAudioEffects[$0] },
            effectConfigurationAvailable: applicationEffectConfigurationAvailable,
            effectPresetsAvailable: applicationEffectPresetsAvailable,
            session: session.map {
                DiagnosticApplicationSessionState(
                    resources: ($0 as? EngineApplicationSession)?.resourceSnapshot
                        ?? ($0 as? ProcessAudioSession)?.resourceSnapshot,
                    mode: $0.mode.diagnosticDescription,
                    output: DiagnosticDeviceRef(id: $0.output.id, uid: $0.output.uid, name: $0.output.name),
                    sourceOutputUID: $0.playbackRoute.sourceOutputUID,
                    tapDeviceUID: $0.playbackRoute.tapDeviceUID,
                    playbackDeviceUIDs: $0.playbackRoute.playbackDeviceUIDs,
                    mainDeviceUID: $0.playbackRoute.mainDeviceUID,
                    isStacked: $0.playbackRoute.isStacked,
                    isActive: $0.isActive,
                    isReleased: $0.isReleased,
                    isSuspendedForOutputChange: $0.isSuspendedForOutputChange
                )
            }
        )
    }

    /// 只在本地报告中保留持久化键，便于把应用身份和错误对应起来；不改变真实路由解析。
    private func applicationRouteStorageKeyForDiagnostics(_ app: ApplicationAudioRow) -> String? {
        guard !app.bundleID.isEmpty else { return nil }
        return "bundle:\(app.bundleID)"
    }

    private func diagnosticRouting(_ state: OutputRoutingState) -> DiagnosticRoutingState {
        let desired = state.desired?.memberUIDs ?? []
        let configured = state.configured?.memberUIDs ?? []
        let confirmedIntent = state.confirmed?.intent.memberUIDs ?? []
        return DiagnosticRoutingState(
            phase: state.phase.diagnosticDescription,
            desiredMembers: desired,
            configuredMembers: configured,
            unavailableMemberUIDs: state.unavailableMemberUIDs,
            confirmedIntentMembers: confirmedIntent,
            confirmedOutput: state.confirmed.map {
                DiagnosticDeviceRef(id: $0.output.id, uid: $0.output.uid, name: $0.output.name)
            },
            actualOutput: state.actualOutput.map {
                DiagnosticDeviceRef(id: $0.id, uid: $0.uid, name: $0.name)
            },
            actualSystemOutputDeviceID: state.actualSystemOutputID,
            pendingCleanup: state.pendingCleanup.map {
                DiagnosticDeviceRef(id: $0.id, uid: $0.uid, name: $0.name)
            },
            completedSteps: state.completedSteps,
            error: state.error,
            warning: state.warning,
            aggregate: state.confirmed?.aggregate.map {
                DiagnosticAggregateState(
                    deviceID: $0.deviceID,
                    uid: $0.uid,
                    outputs: $0.outputs.map {
                        DiagnosticDeviceRef(id: $0.id, uid: $0.uid, name: $0.name)
                    },
                    mainOutputUID: $0.mainOutputUID,
                    previousOutputUID: $0.previousOutputUID,
                    sampleRate: $0.sampleRate
                )
            }
        )
    }
}

extension OutputRoutingPhase {
    var diagnosticDescription: String {
        switch self {
        case .stable: return "stable"
        case .switching: return "switching"
        case .awaitingHAL: return "awaitingHAL"
        case .awaitingMembers: return "awaitingMembers"
        case .confirmed: return "confirmed"
        case .failed: return "failed"
        }
    }
}

private extension AppAudioRoute {
    var diagnosticDescription: String {
        switch self {
        case .allOutputs: return "allOutputs"
        case .custom: return "custom"
        }
    }
}

private extension EffectiveAppAudioRoute {
    var diagnosticDescription: String {
        switch self {
        case .allOutputs: return "allOutputs"
        case .custom: return "custom"
        case .waitingForDevices: return "waitingForDevices"
        case .configurationUnavailable: return "configurationUnavailable"
        }
    }
}

private extension ApplicationAudioMode {
    var diagnosticDescription: String {
        switch self {
        case .metering: return "metering"
        case .mixing: return "mixing"
        }
    }
}

private extension SystemAudioCaptureAccess {
    var diagnosticDescription: String {
        switch self {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .unavailable: return "unavailable"
        }
    }
}

private extension DiagnosticSystemInfo {
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

private extension DiagnosticDeviceControlState {
    init(_ state: AudioDeviceControlState?) {
        switch state {
        case .available(let volume, let mute):
            self.init(state: "available",
                      volume: volume.scalar,
                      volumeWritable: volume.writable,
                      muted: mute.muted,
                      muteWritable: mute.writable,
                      error: volume.error ?? mute.error)
        case .failed(let message):
            self.init(state: "failed", volume: nil, volumeWritable: nil,
                      muted: nil, muteWritable: nil, error: message)
        case nil:
            self.init(state: "notRead", volume: nil, volumeWritable: nil,
                      muted: nil, muteWritable: nil, error: nil)
        }
    }
}
