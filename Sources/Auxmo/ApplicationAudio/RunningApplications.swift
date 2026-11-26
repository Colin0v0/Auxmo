import AppKit
import AuxmoCore

@MainActor
enum RunningApplications {
    static func applications() -> [RunningApplicationInfo] {
        // 进程列表每两秒刷新；路径标准化只做一次，避免嵌套判断反复解析同一个 URL。
        let candidates: [(app: NSRunningApplication, path: String)] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy != .prohibited, app.processIdentifier != getpid(),
                  let bundle = app.bundleURL, bundle.pathExtension == "app" else { return nil }
            return (app: app, path: bundle.standardizedFileURL.path)
        }
        return candidates.filter { candidate in
            // 菜单栏 App 是有效宿主；嵌套在宿主 App 内的 helper 一律归属到宿主。
            !candidates.contains { other in
                other.app.processIdentifier != candidate.app.processIdentifier
                    && candidate.path.hasPrefix(other.path + "/")
            }
        }.map { candidate in
            let app = candidate.app
            let bundleID: String
            if let value = app.bundleIdentifier { bundleID = value } else { bundleID = "" }
            return RunningApplicationInfo(processID: app.processIdentifier, bundleID: bundleID,
                                          name: app.localizedName, bundleURL: app.bundleURL)
        }
    }

    static func rows(records: [AudioProcessRecord], retainedIDs: Set<String> = [], inventory: ProcessInventory? = nil) -> [ApplicationAudioRow] {
        let facts: ProcessInventory
        if let inventory { facts = inventory }
        else { facts = ProcessInventory.capture(processIDs: records.map(\.processID)) }
        return ApplicationCatalog.rows(applications: applications(), records: records,
                                       executableURLs: facts.executableURLs, retainedIDs: retainedIDs,
                                       parentPIDs: facts.parentPIDs, processNames: facts.names)
    }
}
