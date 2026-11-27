import SwiftUI
import AuxmoCore

@MainActor
final class AuxmoDelegate: NSObject, NSApplicationDelegate {
    private var statusPanel: StatusPanelController?
    private var model: AppModel?
    private var startupTask: Task<Void, Never>?
    private var fatalStartupFailure = false
    private let bluetoothPermission = BluetoothPermissionRequest()
    private let audioPermission = AudioCapturePermissionRequest.live
    private let permissionRelaunch = ApplicationRelaunch.live
    private var terminationTask: Task<Void, Never>?
    private lazy var termination = ApplicationTermination(attempt: { [weak self] in
        self?.model?.shutdownStep() ?? .complete
    }, confirmUncleanExit: { [weak self] message in
        self?.model?.diagnosticEventLog.record(category: "shutdown", message: message)
        let alert = ApplicationTermination.makeFailureAlert(message, language: AppSettings.shared.resolvedLanguage)
        return alert.runModal() == .alertSecondButtonReturn
    }, cancelRestart: { [weak self] in
        AuxmoUpdateChecker.shared.cancelPendingRestart()
        self?.permissionRelaunch.cancel()
    }, cancelShutdown: { [weak self] in self?.model?.cancelShutdown() })

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动时先恢复用户保存的主题，避免设置窗口和菜单栏面板首帧使用系统默认外观。
        AppSettings.shared.applyApplicationAppearance()
        let bluetooth = bluetoothPermission
        let audio = audioPermission
        let sequence = StartupPermissionSequence(defaults: .standard,
                                                requestBluetooth: { await bluetooth.request() },
                                                audioAccess: SystemAudioCaptureAccess.current,
                                                requestAudio: { try await audio.request() },
                                                audioIsReleased: { audio.isReleased })
        // 先走系统权限申请，再创建会自动连接耳机的主模型；没有额外引导页面。
        startupTask = Task { @MainActor [weak self] in
            let result = await sequence.run()
            guard !Task.isCancelled, let self else { return }
            guard result.canEnterMainInterface else {
                // 系统明确拒绝时使用 Auxmo 自制提示框，让用户能够前往系统设置；
                // 无论选择设置还是退出，都不进入主界面，也不保留不可用的后台实例。
                if result.audioPermissionDenied {
                    self.presentAudioPermissionDeniedAndQuit()
                    return
                }
                // 授权请求尚未完成或初始化失败时不继续启动；退出进程让系统回收未完成的资源。
                self.fatalStartupFailure = true
                if !result.errors.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "音频初始化失败"
                    alert.informativeText = result.errors.joined(separator: "；")
                    alert.addButton(withTitle: "退出")
                    alert.runModal()
                }
                NSApp.terminate(nil)
                return
            }
            // 使用系统申请回调的明确允许结果直接重启，不等待旧进程缓存的 preflight 变更。
            if result.grantedAudioDuringRequest {
                do {
                    try self.permissionRelaunch.request()
                    return
                } catch {
                    let alert = NSAlert()
                    alert.messageText = AppSettings.shared.localized("自动重启失败")
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: AppSettings.shared.localized("退出"))
                    alert.runModal()
                    self.fatalStartupFailure = true
                    NSApp.terminate(nil)
                    return
                }
            }
            let model = AppModel.shared
            if !result.errors.isEmpty { model.operationError = result.errors.joined(separator: "；") }
            self.model = model
            LowBatteryReminder.shared.start(group: model.headphones)
            self.statusPanel = StatusPanelController(model: model,
                requestAudioPermission: { try await audio.request() }, onAudioPermissionGranted: { [weak self] in
                self?.restartAfterAudioPermissionGrant()
            }, onAudioPermissionDenied: { [weak self] in
                self?.presentAudioPermissionDeniedAndQuit()
            })
            // 启动时保持菜单栏无 Dock 图标模式，同时保留独立音效窗与文本弹窗的键盘激活能力；打开详情窗口时再切换为 .regular 显示 Dock 图标。
            NSApp.setActivationPolicy(.accessory)
            AuxmoUpdateChecker.shared.startAutomaticChecking()
            #if DEBUG
            // 本地界面验收可显式打开详情页，复用正常的窗口创建和 Dock 显示流程。
            if CommandLine.arguments.contains("--show-dashboard") {
                self.statusPanel?.showMainWindowForDock()
            }
            #endif
        }
    }

    /// Dock 图标被点击时复用完整主窗口，而不是只把应用置前却没有可见内容。
    func applicationDidBecomeActive(_ notification: Notification) {
        // 从系统设置返回后复查通知权限。
        LowBatteryReminder.shared.recheckPermission()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusPanel?.showMainWindowForDock()
        return true
    }

    private func presentAudioPermissionDeniedAndQuit() {
        // 权限被拒绝后主界面不可用；终止时跳过业务资源清理，避免清理失败把进程留在后台。
        fatalStartupFailure = true
        AuxmoUpdateChecker.shared.cancelPendingRestart()
        permissionRelaunch.cancel()
        AudioCapturePermissionAlert.present(language: AppSettings.shared.resolvedLanguage)
    }

    private func restartAfterAudioPermissionGrant() {
        // 授权恢复只重启当前包，不同时执行另一条更新安装链。
        AuxmoUpdateChecker.shared.cancelPendingRestart()
        do { try permissionRelaunch.request() }
        catch { model?.operationError = error.localizedDescription }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        startupTask?.cancel()
        bluetoothPermission.cancel()
        audioPermission.cancel()
        // 主模型还不存在时，退出必须生效；系统会随进程结束回收私有探测资源。
        // 不为退出操作构造 AppModel，也不因清理失败把启动留在无界面的后台。
        guard !fatalStartupFailure, model != nil else { return .terminateNow }
        let reply = termination.request(at: ProcessInfo.processInfo.systemUptime)
        if reply == .terminateLater, terminationTask == nil {
            terminationTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) }
                    catch { return }
                    guard let self else { return }
                    if let decision = self.termination.poll(at: ProcessInfo.processInfo.systemUptime) {
                        self.terminationTask = nil
                        NSApp.reply(toApplicationShouldTerminate: decision)
                        return
                    }
                }
            }
        }
        return reply
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 未完整清理的退出已撤销更新意图；只有正常清理完成才会启动替换 helper。
        AuxmoUpdateChecker.shared.launchInstallerIfPending()
    }
}

struct AuxmoApp: App {
    @NSApplicationDelegateAdaptor(AuxmoDelegate.self) private var delegate

    init() {
        // 发布脚本用这个入口验证下载包内的资源 bundle 能真正被当前 App 加载。
        if CommandLine.arguments.contains("--diagnose-resources") {
            let image = AuxmoBrandAsset.template
            let bundlePath = AuxmoBrandAsset.bundle.bundleURL.standardizedFileURL.path
            guard let resourceRoot = Bundle.main.resourceURL?.standardizedFileURL.path,
                  bundlePath == resourceRoot + "/Auxmo_Auxmo.bundle" else {
                FileHandle.standardError.write(Data("资源包没有从当前 App 加载：\(bundlePath)\n".utf8))
                exit(1)
            }
            let report: [String: Any] = [
                "bundlePath": bundlePath,
                "templateWidth": Int(image.size.width),
                "templateHeight": Int(image.size.height)
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: report,
                                                      options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("资源诊断失败：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        // 诊断入口只读取真实 HAL 状态；失败返回非零，不启动窗口和蓝牙。
        if CommandLine.arguments.contains("--diagnose-applications") {
            do {
                let records = try AudioProcesses.records()
                let inventory = ProcessInventory.capture(processIDs: records.map(\.processID))
                let report = ApplicationDiagnosis(registeredProcessCount: records.count,
                                                  activeOutputProcessCount: records.filter(\.isRunningOutput).count,
                                                  applications: RunningApplications.rows(records: records, inventory: inventory),
                                                  processes: records, processInfo: inventory)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(report))
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("应用音频诊断失败：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--diagnose-inputs") {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(SystemInput.snapshot()))
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("输入设备诊断失败：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--diagnose") {
            do {
                let snapshot = try SystemAudio.snapshot()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Auxmo 诊断失败：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    var body: some Scene {
        // 窗口与菜单栏弹窗由同一个原生控制器持有，启动不额外弹出控制窗口。
        // 保留 SwiftUI 的应用生命周期与命令系统，不创建隐藏的 MenuBarExtra 宿主。
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

private struct ApplicationDiagnosis: Encodable {
    let registeredProcessCount: Int
    let activeOutputProcessCount: Int
    let applications: [ApplicationAudioRow]
    let processes: [AudioProcessRecord]
    let processInfo: ProcessInventory
}
