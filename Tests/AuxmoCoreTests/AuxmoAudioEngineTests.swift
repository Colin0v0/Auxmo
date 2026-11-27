import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import AuxmoCore

struct AuxmoAudioEngineTests {
    private let speaker = AudioOutput(id: 11, uid: "speaker", name: "Mac 扬声器", transport: kAudioDeviceTransportTypeBuiltIn)
    private let headphone = AudioOutput(id: 12, uid: "headphone", name: "蓝牙耳机", transport: kAudioDeviceTransportTypeBluetooth)
    private let usb = AudioOutput(id: 13, uid: "usb", name: "USB 声卡", transport: kAudioDeviceTransportTypeUSB)

    @Test func plannerCompilesNodesSinksAndCausalExplanations() throws {
        let aggregate = AudioOutput(id: 99, uid: "com.colin0v0.auxmo.multi.1", name: "Auxmo 多设备输出",
                                    transport: kAudioDeviceTransportTypeAggregate)
        let multiRoute = MultiOutputRoute(deviceID: 99, uid: aggregate.uid,
                                          outputs: [speaker, headphone, usb],
                                          mainOutputUID: speaker.uid,
                                          previousOutputUID: speaker.uid,
                                          sampleRate: 48_000)
        let confirmed = ConfirmedOutputRoute(
            intent: .simultaneous([speaker.uid, headphone.uid, usb.uid]),
            output: aggregate,
            aggregate: multiRoute
        )
        let snapshot = SystemAudioSnapshot(outputs: [speaker, headphone, usb, aggregate],
                                           selectedID: aggregate.id,
                                           controls: [:])

        let musicGroup = AudioProcessGroup(id: "bundle:test.music", bundleID: "test.music",
                                           processIDs: [101], objectIDs: [201])
        let browserGroup = AudioProcessGroup(id: "bundle:test.browser", bundleID: "test.browser",
                                             processIDs: [102], objectIDs: [202])
        let idleGroup = AudioProcessGroup(id: "bundle:test.podcast", bundleID: "test.podcast",
                                          processIDs: [103], objectIDs: [203])

        let musicRow = ApplicationAudioRow(id: musicGroup.id, bundleID: musicGroup.bundleID, name: "Music",
                                           applicationURL: nil, group: musicGroup, isRunningOutput: true)
        let browserRow = ApplicationAudioRow(id: browserGroup.id, bundleID: browserGroup.bundleID, name: "Browser",
                                             applicationURL: nil, group: browserGroup, isRunningOutput: true)
        let podcastRow = ApplicationAudioRow(id: idleGroup.id, bundleID: idleGroup.bundleID, name: "Podcast",
                                             applicationURL: nil, group: idleGroup, isRunningOutput: true)

        var musicMix = ApplicationMixState()
        try musicMix.setGain(0.6)
        musicMix.enable(outputUID: aggregate.uid)

        var musicEffect = AppAudioEffectSettings(enabled: true, preset: .bassBoost)
        musicEffect.spatial.selectMode(.room)
        musicEffect.dynamics = .light
        musicEffect.channel.balance = -0.25

        let world = AudioEngineWorld(
            excludedPID: 9999,
            captureAccess: .authorized,
            routeConfigurationAvailable: true,
            effectConfigurationAvailable: true,
            effectsEnabled: true,
            metersVisible: true,
            routingPolicy: .authorizedGroupOnly,
            audioSnapshot: snapshot,
            confirmedRoute: confirmed,
            multiOutputRoute: multiRoute,
            configuredMemberUIDs: [speaker.uid, headphone.uid, usb.uid],
            unavailableMemberUIDs: [usb.uid],
            applications: [musicRow, browserRow, podcastRow],
            mixStates: [musicRow.id: musicMix, browserRow.id: ApplicationMixState(), podcastRow.id: ApplicationMixState()],
            storedRoutes: [
                "bundle:test.music": .custom(deviceUIDs: [headphone.uid]),
                "bundle:test.podcast": .custom(deviceUIDs: [usb.uid])
            ],
            effectiveEffects: ["bundle:test.music": musicEffect]
        )

        let plan = AudioGraphPlanner.compile(world)

        let musicExplanation = try #require(plan.explanations[musicRow.id])
        #expect(musicExplanation.disposition == .routed)
        #expect(musicExplanation.rule == .customSelection)
        #expect(musicExplanation.activeSinkUIDs == [headphone.uid])
        #expect(musicExplanation.activeNodes == [
            .sourceTap, .gainMute, .equalizer, .spatial, .dynamics, .channel,
            .meterProbe, .routeCrossfade, .sinkSummingBus, .sinkSafetyLimiter
        ])

        // 仅打开电平观察的浏览器只建立只读计量源，不占用任何引擎输出 Sink。
        let browserExplanation = try #require(plan.explanations[browserRow.id])
        #expect(browserExplanation.disposition == .meteringOnly)
        #expect(browserExplanation.activeSinkUIDs == [speaker.uid, headphone.uid])
        #expect(browserExplanation.activeNodes == [.sourceTap, .meterProbe])

        // 唯一自定义目标 usb 当前不可用：保持静音等待，绝不扩流到扬声器或耳机。
        let podcastExplanation = try #require(plan.explanations[podcastRow.id])
        #expect(podcastExplanation.disposition == .pausedWaitingForDevices)
        #expect(podcastExplanation.activeSinkUIDs.isEmpty)
        #expect(podcastExplanation.unavailableSinkUIDs == [usb.uid])
        #expect(plan.sources[podcastRow.id]?.suspended == true)

        // 整个引擎计划只需要启动 headphone 这 1 台物理 Sink。
        #expect(Array(plan.sinks.keys) == [headphone.uid])
        #expect(plan.edges == [PlannedRouteEdge(sourceID: musicRow.id, sinkUID: headphone.uid)])
    }

    @Test func plannerSupportsIndependentPhysicalDeviceRoutingWithoutMultiOutputAggregate() {
        let snapshot = SystemAudioSnapshot(outputs: [speaker, headphone, usb],
                                           selectedID: speaker.id,
                                           controls: [:])
        let confirmed = ConfirmedOutputRoute(intent: .single(speaker.uid), output: speaker, aggregate: nil)
        let group = AudioProcessGroup(id: "bundle:test.player", bundleID: "test.player",
                                      processIDs: [200], objectIDs: [300])
        let row = ApplicationAudioRow(id: group.id, bundleID: group.bundleID, name: "Player",
                                      applicationURL: nil, group: group, isRunningOutput: true)

        let world = AudioEngineWorld(
            excludedPID: 9999,
            routingPolicy: .independentPhysicalOutputs,
            audioSnapshot: snapshot,
            confirmedRoute: confirmed,
            applications: [row],
            mixStates: [row.id: ApplicationMixState()],
            storedRoutes: ["bundle:test.player": .custom(deviceUIDs: [headphone.uid, usb.uid])]
        )
        let plan = AudioGraphPlanner.compile(world)
        #expect(plan.explanations[row.id]?.disposition == .routed)
        #expect(plan.explanations[row.id]?.activeSinkUIDs == [headphone.uid, usb.uid])
        #expect(Set(plan.sinks.keys) == Set([headphone.uid, usb.uid]))
    }

    @Test @MainActor func selfProcessIsExcludedToPreventFeedbackLoop() {
        let selfPID: Int32 = 4242
        let pureSelf = AudioProcessGroup(id: "self", bundleID: "com.colin0v0.auxmo.app",
                                         processIDs: [selfPID], objectIDs: [88])
        #expect(AudioGraphPlanner.sanitizeGroup(pureSelf, excludedPID: selfPID) == nil)
        #expect(throws: AudioFailure.self) {
            _ = try AudioAppSource.makeTapDescription(
                group: pureSelf, tapDeviceUID: "speaker", mode: .mixing, suspended: false, excludedPID: selfPID
            )
        }

        let mixed = AudioProcessGroup(id: "mixed", bundleID: "test.app",
                                      processIDs: [selfPID, 777], objectIDs: [88, 99])
        let sanitized = AudioGraphPlanner.sanitizeGroup(mixed, excludedPID: selfPID)
        #expect(sanitized?.processIDs == [777])
        #expect(sanitized?.objectIDs == [99])
    }

    @Test func ringBufferResamplesAcrossSampleRatesAndClockDriftWithoutUnderruns() {
        let ring = AudioBroadcastRingBuffer(capacityFrames: 16_384, sampleRate: 48_000)
        var reader44k = AudioSinkEdgeReader(sinkSampleRate: 44_100, initialGain: 1)
        var reader96k = AudioSinkEdgeReader(sinkSampleRate: 96_000, initialGain: 1)

        let sourceChunk = 480 // 10ms @ 48kHz
        let sink44Chunk = 442 // 模拟轻微正漂移（约 +2200 ppm）
        let sink96Chunk = 960 // 10ms @ 96kHz

        var phase: Double = 0
        var sourceSamples = [Float](repeating: 0, count: sourceChunk * 2)
        let bus44L = UnsafeMutablePointer<Float>.allocate(capacity: sink44Chunk)
        let bus44R = UnsafeMutablePointer<Float>.allocate(capacity: sink44Chunk)
        let bus96L = UnsafeMutablePointer<Float>.allocate(capacity: sink96Chunk)
        let bus96R = UnsafeMutablePointer<Float>.allocate(capacity: sink96Chunk)
        defer {
            bus44L.deallocate(); bus44R.deallocate()
            bus96L.deallocate(); bus96R.deallocate()
        }

        // 先预充 30ms 数据以覆盖双时钟缓冲水位。
        for _ in 0..<3 {
            for i in 0..<sourceChunk {
                let s = Float(sin(phase)) * 0.5
                phase += 2 * .pi * 440 / 48_000
                sourceSamples[i * 2] = s
                sourceSamples[i * 2 + 1] = -s
            }
            ring.writeInterleaved(sourceSamples, frames: sourceChunk, channels: 2)
        }

        var peak44: Float = 0
        var peak96: Float = 0
        for block in 0..<120 {
            for i in 0..<sourceChunk {
                let s = Float(sin(phase)) * 0.5
                phase += 2 * .pi * 440 / 48_000
                sourceSamples[i * 2] = s
                sourceSamples[i * 2 + 1] = -s
            }
            ring.writeInterleaved(sourceSamples, frames: sourceChunk, channels: 2)

            memset(bus44L, 0, sink44Chunk * 4)
            memset(bus44R, 0, sink44Chunk * 4)
            memset(bus96L, 0, sink96Chunk * 4)
            memset(bus96R, 0, sink96Chunk * 4)

            _ = reader44k.mixIntoBus(from: ring, leftBus: bus44L, rightBus: bus44R,
                                     frames: sink44Chunk, sinkSampleRate: 44_100, disconnecting: false)
            _ = reader96k.mixIntoBus(from: ring, leftBus: bus96L, rightBus: bus96R,
                                     frames: sink96Chunk, sinkSampleRate: 96_000, disconnecting: false)

            if block > 10 {
                for i in 0..<sink44Chunk {
                    #expect(bus44L[i].isFinite && bus44R[i].isFinite)
                    peak44 = max(peak44, abs(bus44L[i]))
                }
                for i in 0..<sink96Chunk {
                    #expect(bus96L[i].isFinite && bus96R[i].isFinite)
                    peak96 = max(peak96, abs(bus96L[i]))
                }
            }
        }

        #expect(peak44 > 0.45 && peak44 < 0.55)
        #expect(peak96 > 0.45 && peak96 < 0.55)
    }

    @Test @MainActor func multipleAppsShareOnePhysicalDeviceSinkAndMasterLimiterPreventsClipping() throws {
        let harness = EngineTestHarness()
        let engine = harness.makeEngine()

        let music = AudioProcessGroup(id: "bundle:music", bundleID: "music", processIDs: [10], objectIDs: [110])
        let browser = AudioProcessGroup(id: "bundle:browser", bundleID: "browser", processIDs: [11], objectIDs: [111])
        let game = AudioProcessGroup(id: "bundle:game", bundleID: "game", processIDs: [12], objectIDs: [112])

        let s1 = engine.makeSession(group: music, output: speaker, mode: .mixing)
        let s2 = engine.makeSession(group: browser, output: speaker, mode: .mixing)
        let s3 = engine.makeSession(group: game, output: speaker, mode: .mixing)

        try s1.setGain(0.9)
        try s2.setGain(0.9)
        try s3.setGain(0.9)
        try s1.start()
        try s2.start()
        try s3.start()

        // 三个独立应用混音到同一物理扬声器时，底层只注册并启动 1 个共享物理 Sink IOProc！
        #expect(harness.sinkCreatedDevices == [speaker.id])
        #expect(engine.activeSinkUIDs == [speaker.uid])
        #expect(engine.diagnosticSnapshot.activeSourceCount == 3)
        #expect(engine.diagnosticSnapshot.activeSinkCount == 1)
        #expect(engine.diagnosticSnapshot.activeEdgeCount == 3)

        // 连续驱动源捕获与共享物理 Sink 渲染：3 × 0.8 = 2.4，Master Limiter 必须将输出严格限制在 <= 0.98。
        for _ in 0..<8 {
            harness.pumpSource(tapID: 1, amplitude: 0.8, frames: 512)
            harness.pumpSource(tapID: 2, amplitude: 0.8, frames: 512)
            harness.pumpSource(tapID: 3, amplitude: 0.8, frames: 512)
        }
        var maxOutput: Float = 0
        for _ in 0..<6 {
            harness.pumpSource(tapID: 1, amplitude: 0.8, frames: 512)
            harness.pumpSource(tapID: 2, amplitude: 0.8, frames: 512)
            harness.pumpSource(tapID: 3, amplitude: 0.8, frames: 512)
            let rendered = harness.pullSink(deviceID: speaker.id, frames: 512)
            maxOutput = max(maxOutput, rendered.map { abs($0) }.max() ?? 0)
        }
        #expect(maxOutput > 0.5)
        #expect(maxOutput <= 0.9801)

        try engine.shutdown()
        #expect(engine.activeSinkUIDs.isEmpty)
        #expect(s1.isReleased && s2.isReleased && s3.isReleased)
    }

    @Test @MainActor func hotRouteSwitchCrossfadesSinksWithoutInterruptingSourceCapture() throws {
        let harness = EngineTestHarness()
        let engine = harness.makeEngine()
        let aggregate = AudioOutput(id: 99, uid: "com.colin0v0.auxmo.multi.hot", name: "Auxmo 多设备输出",
                                    transport: kAudioDeviceTransportTypeAggregate)
        let routeHeadphone = try ApplicationPlaybackRoute(
            output: aggregate,
            playbackOutputs: [headphone],
            groupOutputs: [speaker, headphone],
            mainOutputUID: speaker.uid
        )
        let routeSpeaker = try ApplicationPlaybackRoute(
            output: aggregate,
            playbackOutputs: [speaker],
            groupOutputs: [speaker, headphone],
            mainOutputUID: speaker.uid
        )
        let group = AudioProcessGroup(id: "bundle:music", bundleID: "music", processIDs: [10], objectIDs: [110])
        let session = engine.makeSession(group: group, output: aggregate, playbackRoute: routeHeadphone, mode: .mixing)
        try session.start()

        #expect(harness.createdTaps == 1)
        #expect(harness.stoppedSourceCaptures == 0)
        #expect(engine.activeSinkUIDs == [headphone.uid])

        for _ in 0..<6 { harness.pumpSource(tapID: 1, amplitude: 0.6, frames: 512) }
        _ = harness.pullSink(deviceID: headphone.id, frames: 512)

        // 热切换到扬声器：捕获源都是 speaker，Source IO 不停止、Tap 不销毁，耳机平滑淡出后自动回收！
        try session.switchOutput(to: aggregate, playbackRoute: routeSpeaker)
        #expect(harness.createdTaps == 1)
        #expect(harness.stoppedSourceCaptures == 0)
        #expect(Set(engine.activeSinkUIDs) == Set([headphone.uid, speaker.uid]))

        // 驱动耳机完成 20ms 淡出（48kHz 下约 960 帧），随后回收空闲 Sink。
        for _ in 0..<4 {
            harness.pumpSource(tapID: 1, amplitude: 0.6, frames: 512)
            _ = harness.pullSink(deviceID: headphone.id, frames: 512)
            _ = harness.pullSink(deviceID: speaker.id, frames: 512)
        }
        try engine.releaseIdleSinks()
        #expect(engine.activeSinkUIDs == [speaker.uid])

        try engine.shutdown()
    }

    @Test @MainActor func physicalOutputSwitchKeepsProcessCaptureRunning() throws {
        let harness = EngineTestHarness()
        let engine = harness.makeEngine()
        let group = AudioProcessGroup(id: "bundle:music", bundleID: "music", processIDs: [10], objectIDs: [110])
        let session = engine.makeSession(group: group, output: speaker, mode: .mixing)

        try session.start()
        #expect(harness.createdTaps == 1)
        #expect(engine.activeSinkUIDs == [speaker.uid])

        for _ in 0..<6 { harness.pumpSource(tapID: 1, amplitude: 0.6, frames: 512) }
        _ = harness.pullSink(deviceID: speaker.id, frames: 512)

        // 真实设备切换只替换 Sink 边，进程混音 Tap 与捕获 IO 保持连续。
        try session.switchOutput(to: headphone, playbackRoute: .single(headphone))
        #expect(harness.createdTaps == 1)
        #expect(harness.stoppedSourceCaptures == 0)
        #expect(Set(engine.activeSinkUIDs) == Set([speaker.uid, headphone.uid]))

        for _ in 0..<4 {
            harness.pumpSource(tapID: 1, amplitude: 0.6, frames: 512)
            _ = harness.pullSink(deviceID: speaker.id, frames: 512)
            _ = harness.pullSink(deviceID: headphone.id, frames: 512)
        }
        try engine.releaseIdleSinks()
        #expect(engine.activeSinkUIDs == [headphone.uid])

        try engine.shutdown()
    }

    @Test @MainActor func readOnlyMeteringNeverCreatesOutputSinks() throws {
        let harness = EngineTestHarness()
        let engine = harness.makeEngine()
        let group = AudioProcessGroup(id: "bundle:meter", bundleID: "meter", processIDs: [55], objectIDs: [155])
        let session = engine.makeSession(group: group, output: speaker, mode: .metering)
        try session.start()
        #expect(harness.sinkCreatedDevices.isEmpty)
        #expect(engine.activeSinkUIDs.isEmpty)

        harness.pumpSource(tapID: 1, amplitude: 0.42, frames: 256)
        let peak = try #require(session.consumePeak())
        #expect(abs(peak - 0.42) < 0.001)
        try session.stop()
        #expect(session.isReleased)
    }

    @Test func dynamicsBypassCrossfadesSmoothlyWithoutTwentyMillisecondStepPop() {
        var dsp = AppAudioEffectDSP(sampleRate: 48_000)
        var active = AppAudioEffectSettings(enabled: true)
        active.dynamics = .strong
        active.channel.swap = true
        dsp.beginBuffer(
            effectWord: AppAudioEffectParameterWord.pack(active),
            spatialWord: AppAudioSpatialParameterWord.pack(active),
            dynamicsWord: AppAudioDynamicsParameterWord.pack(active)
        )

        var previousLeft: Float = 0.6
        for _ in 0..<24_000 {
            _ = dsp.beginFrame()
            var pair = (left: dsp.processPrelimiter(0.6, channel: 0), right: dsp.processPrelimiter(0.2, channel: 1))
            dsp.processSpatial(&pair, channels: 2)
            dsp.processDynamics(&pair, channels: 2)
            let out = dsp.limitFrame(&pair, channels: 2)
            previousLeft = out.0
        }

        // 关闭音效：检查整个 30ms 过渡期逐帧跳变，绝不能在 20ms 结束点出现阶跃跳变。
        dsp.beginBuffer(
            effectWord: AppAudioEffectParameterWord.pack(.disabled),
            spatialWord: AppAudioSpatialParameterWord.pack(.disabled),
            dynamicsWord: AppAudioDynamicsParameterWord.pack(.disabled)
        )
        var maxStepJump: Float = 0
        for _ in 0..<1_500 {
            let outLeft: Float
            if dsp.beginFrame() {
                var pair = (left: dsp.processPrelimiter(0.6, channel: 0), right: dsp.processPrelimiter(0.2, channel: 1))
                dsp.processSpatial(&pair, channels: 2)
                dsp.processDynamics(&pair, channels: 2)
                outLeft = dsp.limitFrame(&pair, channels: 2).0
            } else {
                outLeft = 0.6
            }
            maxStepJump = max(maxStepJump, abs(outLeft - previousLeft))
            previousLeft = outLeft
        }
        #expect(maxStepJump < 0.01)
        #expect(abs(previousLeft - 0.6) < 0.0001)
    }

    @Test func nonFiniteMessagePackDoubleReturnsNilIntInsteadOfTrapping() {
        #expect(MessagePackValue.double(.nan).intValue == nil)
        #expect(MessagePackValue.double(.infinity).intValue == nil)
        #expect(MessagePackValue.double(-.infinity).intValue == nil)
        #expect(MessagePackValue.double(42).intValue == 42)
    }

    @Test func headphoneConnectionGuardSkipsStaleBadObjectsAndInputOnlySiblingHandles() throws {
        // ID 1 是刚销毁的无关残留对象（!obj），ID 2 是同一耳机的 HFP 输入句柄，ID 3 是真实 A2DP 蓝牙输出句柄。
        try HeadphoneConnectionGuard.check(
            "airpods",
            deviceIDs: [1, 2, 3],
            readUID: { id in
                if id == 1 { throw AudioFailure("残留对象", status: HAL.badObjectStatus) }
                return "airpods"
            },
            isConnectedBluetoothOutput: { id in id == 3 }
        )
    }
}

@MainActor
private final class EngineTestHarness {
    let speaker = AudioOutput(id: 11, uid: "speaker", name: "Mac 扬声器", transport: kAudioDeviceTransportTypeBuiltIn)
    let headphone = AudioOutput(id: 12, uid: "headphone", name: "蓝牙耳机", transport: kAudioDeviceTransportTypeBluetooth)
    let usb = AudioOutput(id: 13, uid: "usb", name: "USB 声卡", transport: kAudioDeviceTransportTypeUSB)
    let format = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )

    var createdTaps = 0
    var stoppedSourceCaptures = 0
    var sinkCreatedDevices: [AudioDeviceID] = []

    private var nextTapID: AudioObjectID = 1
    private var nextCaptureAggID: AudioDeviceID = 500
    private var tapToCaptureDevice: [AudioObjectID: AudioDeviceID] = [:]
    private var lastTappedID: AudioObjectID = 0
    private var sourceCallbacks: [AudioDeviceID: (AudioDeviceIOProc, UnsafeMutableRawPointer)] = [:]
    private var sinkCallbacks: [AudioDeviceID: (AudioDeviceIOProc, UnsafeMutableRawPointer)] = [:]

    func makeEngine() -> AuxmoAudioEngine {
        let sourceHW = AudioSourceHardware(
            createTap: { _ in
                let id = self.nextTapID
                self.nextTapID += 1
                self.createdTaps += 1
                self.lastTappedID = id
                return id
            },
            updateTap: { _, _ in },
            tapFormat: { _ in self.format },
            createCaptureAggregate: { _ in
                let id = self.nextCaptureAggID
                self.nextCaptureAggID += 1
                self.tapToCaptureDevice[self.lastTappedID] = id
                return id
            },
            captureFormat: { _ in self.format },
            createIO: { deviceID, proc, ctx in
                self.sourceCallbacks[deviceID] = (proc, ctx)
                return proc
            },
            startIO: { _, _ in noErr },
            stopIO: { _, _ in self.stoppedSourceCaptures += 1; return noErr },
            destroyIO: { deviceID, _ in self.sourceCallbacks.removeValue(forKey: deviceID); return noErr },
            destroyAggregate: { _ in noErr },
            destroyTap: { _ in noErr },
            deviceExists: { _ in false },
            tapExists: { _ in false },
            processRoutes: { _ in [] }
        )

        let sinkHW = AudioSinkHardware(
            outputFormat: { _ in self.format },
            createIO: { deviceID, proc, ctx in
                self.sinkCreatedDevices.append(deviceID)
                self.sinkCallbacks[deviceID] = (proc, ctx)
                return proc
            },
            startIO: { _, _ in noErr },
            stopIO: { _, _ in noErr },
            destroyIO: { deviceID, _ in self.sinkCallbacks.removeValue(forKey: deviceID); return noErr },
            deviceExists: { _ in false },
            validateOutput: { output in
                if output.isAggregate { throw AudioFailure("不允许聚合作为物理 Sink") }
            }
        )

        let engine = AuxmoAudioEngine(sourceHardware: sourceHW, sinkHardware: sinkHW, excludedPID: 99_999)
        engine.updatePhysicalOutputs([speaker, headphone, usb])
        return engine
    }

    func pumpSource(tapID: AudioObjectID, amplitude: Float, frames: Int) {
        guard let deviceID = tapToCaptureDevice[tapID],
              let (proc, ctx) = sourceCallbacks[deviceID] else { return }
        let inputSamples = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        let outputSamples = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        inputSamples.initialize(repeating: amplitude, count: frames * 2)
        outputSamples.initialize(repeating: 0, count: frames * 2)
        defer { inputSamples.deallocate(); outputSamples.deallocate() }

        let inList = AudioBufferList.allocate(maximumBuffers: 1)
        let outList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { inList.unsafeMutablePointer.deallocate(); outList.unsafeMutablePointer.deallocate() }
        inList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: inputSamples)
        outList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: outputSamples)
        var ts = AudioTimeStamp()
        _ = proc(deviceID, &ts, inList.unsafePointer, &ts, outList.unsafeMutablePointer, &ts, ctx)
    }

    func pullSink(deviceID: AudioDeviceID, frames: Int) -> [Float] {
        guard let (proc, ctx) = sinkCallbacks[deviceID] else { return [] }
        let inputSamples = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        let outSamples = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        inputSamples.initialize(repeating: 0, count: frames * 2)
        outSamples.initialize(repeating: 0, count: frames * 2)
        defer { inputSamples.deallocate(); outSamples.deallocate() }

        let inList = AudioBufferList.allocate(maximumBuffers: 1)
        let outList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { inList.unsafeMutablePointer.deallocate(); outList.unsafeMutablePointer.deallocate() }
        inList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: inputSamples)
        outList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: outSamples)
        var ts = AudioTimeStamp()
        _ = proc(deviceID, &ts, inList.unsafePointer, &ts, outList.unsafeMutablePointer, &ts, ctx)
        return Array(UnsafeBufferPointer(start: outSamples, count: frames * 2))
    }
}
