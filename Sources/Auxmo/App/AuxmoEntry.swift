import AppKit

/// 正常入口仍由 SwiftUI 管理；硬件诊断单独运行，不创建第二个 AppModel 或控制器。
@main
enum AuxmoEntry {
    #if DEBUG
    private static var developmentLock: DevelopmentInstanceLock?
    #endif

    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose-headphones") {
            // 正式版和开发版都可能占用耳机控制通道，诊断前必须同时检查。
            let running = ["com.colin0v0.auxmo.app", "com.colin0v0.auxmo.develop"].flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0)
            }
                .filter { $0.processIdentifier != getpid() }
            guard running.isEmpty else {
                FileHandle.standardError.write(Data("请先退出正在运行的 Auxmo，再执行耳机诊断，避免控制通道竞争。\n".utf8))
                exit(1)
            }
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task { @MainActor in await HeadphoneDiagnostic.run() }
            NSApplication.shared.run()
        } else {
            #if DEBUG
            do {
                // 同一个用户的所有开发构建共享锁，不影响独立身份的正式版。
                let lockURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("com.colin0v0.auxmo.develop.lock")
                guard let lock = try DevelopmentInstanceLock.acquire(at: lockURL) else { return }
                developmentLock = lock
            } catch {
                FileHandle.standardError.write(Data("无法确认开发版实例状态：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            #endif
            AuxmoApp.main()
        }
    }
}
