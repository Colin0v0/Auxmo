import Darwin
import Foundation
import AuxmoUpdateSupport

/// 独立 helper 入口不依赖正在运行的 App；等待旧进程退出后按事务替换 bundle，再请求重新启动。
@main
enum AuxmoUpdateHelperMain {
    static func main() {
        // 让 helper 脱离 App 的会话/进程组，避免 App 退出时被 launchd 一并回收。
        _ = setsid()
        do {
            if CommandLine.arguments.contains("--relaunch") {
                try relaunch(options: RelaunchOptions(arguments: CommandLine.arguments))
            } else {
                let options = try Options(arguments: CommandLine.arguments)
                try run(options: options)
            }
            exit(0)
        } catch {
            let message = "更新 helper 失败：\(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            appendLog(message)
            exit(1)
        }
    }

    /// 仅重启当前应用，不替换包、不改隔离标记，也不读取更新暂存目录。
    private static func relaunch(options: RelaunchOptions) throws {
        let app = URL(fileURLWithPath: options.appPath)
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        #if DEBUG
        let expectedBundleIdentifier = "com.colin0v0.auxmo.develop"
        #else
        let expectedBundleIdentifier = "com.colin0v0.auxmo.app"
        #endif
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == expectedBundleIdentifier,
              plist["CFBundleShortVersionString"] as? String == options.version else {
            throw HelperError.invalidPayload
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try waitForExit(pid: options.pid)
        // 不使用 -n：如果 macOS 自己已经重新打开应用，则复用该实例，避免双进程处理音频。
        _ = try run("/usr/bin/open", ["-g", app.path])
        appendLog("系统音频授权后已重新打开 Auxmo\n")
    }

    private static func run(options: Options) throws {
        appendLog("等待 Auxmo 退出，PID \(options.pid)\n")
        try waitForExit(pid: options.pid)
        try validatePayload(options: options)

        let appURL = URL(fileURLWithPath: options.appPath)
        let stage = URL(fileURLWithPath: options.stagePath, isDirectory: true)
        try UpdateInstallation().perform(app: appURL, stage: stage) { app in
            let openResult = try run("/usr/bin/open", ["-n", "-g", app.path])
            appendLog("新版本启动命令已执行：\(openResult)\n")
        }
    }

    private static func validatePayload(options: Options) throws {
        let payload = URL(fileURLWithPath: options.stagePath, isDirectory: true)
            .appendingPathComponent("payload", isDirectory: true)
        let infoURL = payload.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw HelperError.invalidPayload
        }
        guard plist["CFBundleIdentifier"] as? String == "com.colin0v0.auxmo.app" else {
            throw HelperError.invalidPayload
        }
        guard plist["CFBundleShortVersionString"] as? String == options.version else {
            throw HelperError.versionMismatch
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", payload.path])
    }

    private static func waitForExit(pid: Int32) throws {
        // 最多等一分钟；正常退出通常只需几百毫秒。
        for _ in 0..<600 {
            if kill(pid, 0) != 0, errno == ESRCH { return }
            usleep(100_000)
        }
        throw HelperError.processStillRunning
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw HelperError.commandFailed(output.isEmpty ? "退出码 \(process.terminationStatus)" : output)
        }
        return output
    }

    private static func appendLog(_ message: String) { BoundedUpdateLog.record(message) }
}

/// 重启参数不接受更新暂存目录，避免普通授权恢复误走安装流程。
private struct RelaunchOptions {
    let pid: Int32
    let appPath: String
    let version: String

    init(arguments: [String]) throws {
        func value(after key: String) throws -> String {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else {
                throw HelperError.invalidArguments
            }
            return arguments[index + 1]
        }
        guard let pid = Int32(try value(after: "--pid")), pid > 0 else {
            throw HelperError.invalidArguments
        }
        self.pid = pid
        appPath = try value(after: "--app")
        version = try value(after: "--version")
        guard appPath.hasPrefix("/"), appPath.hasSuffix(".app"), !version.isEmpty else {
            throw HelperError.invalidArguments
        }
    }
}

private struct Options {
    let pid: Int32
    let appPath: String
    let stagePath: String
    let version: String

    init(arguments: [String]) throws {
        func value(after key: String) throws -> String {
            guard let index = arguments.firstIndex(of: key),
                  arguments.indices.contains(index + 1) else {
                throw HelperError.invalidArguments
            }
            return arguments[index + 1]
        }
        guard let pid = Int32(try value(after: "--pid")) else {
            throw HelperError.invalidArguments
        }
        self.pid = pid
        appPath = try value(after: "--app")
        stagePath = try value(after: "--stage")
        version = try value(after: "--version")
    }
}

private enum HelperError: LocalizedError {
    case invalidArguments
    case processStillRunning
    case missingPayload
    case invalidPayload
    case versionMismatch
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments: return "更新 helper 参数无效"
        case .processStillRunning: return "等待旧 Auxmo 退出超时"
        case .missingPayload: return "暂存的新版本不存在"
        case .invalidPayload: return "暂存的新版本不是有效的 Auxmo"
        case .versionMismatch: return "暂存版本与目标版本不一致"
        case .commandFailed(let message): return message
        }
    }
}
