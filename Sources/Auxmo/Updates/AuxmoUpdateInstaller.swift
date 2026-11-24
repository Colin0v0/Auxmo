import Foundation
import AuxmoUpdateSupport
import AuxmoCore

/// 更新文件始终放在应用同卷的隐藏目录，helper 替换后才能继续在同一路径重启。
enum AuxmoUpdateInstaller {
    struct Paths: Sendable {
        let stage: URL
        let archive: URL
        let extracted: URL
        let payload: URL
        let oldBundle: URL
    }

    static let stageDirectoryName = ".auxmo-update"

    static var appURL: URL {
        Bundle.main.bundleURL.standardizedFileURL
    }

    static var stageURL: URL {
        appURL.deletingLastPathComponent().appendingPathComponent(stageDirectoryName, isDirectory: true)
    }

    static func prepareStaging(for update: AuxmoAvailableUpdate) throws -> Paths {
        // 正式更新包不能覆盖开发构建，否则两者又会变成同一个应用身份。
        guard Bundle.main.bundleIdentifier == "com.colin0v0.auxmo.app" else {
            throw AuxmoUpdateError.developmentBuild
        }
        let parent = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw AuxmoUpdateError.appDirectoryNotWritable(parent.path)
        }
        try removeStaging()
        let stage = stageURL
        let extracted = stage.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let paths = Paths(stage: stage,
                          archive: stage.appendingPathComponent("Auxmo-\(update.version).\(update.archiveKind.rawValue)"),
                          extracted: extracted,
                          payload: stage.appendingPathComponent("payload", isDirectory: true),
                          oldBundle: stage.appendingPathComponent("old", isDirectory: true))
        try writeMetadata(update: update, paths: paths)
        return paths
    }

    static func verifyAndPrepareDownloadedArchive(update: AuxmoAvailableUpdate,
                                                   paths: Paths) throws {
        let digest = try AuxmoSHA256.hexDigest(at: paths.archive)
        guard digest == update.sha256 else {
            do { try UpdateArchiveExtractor.removeIfPresent(paths.archive) }
            catch {
                throw UpdateArchiveError.cleanupFailed(operation: AuxmoUpdateError.checksumMismatch.localizedDescription,
                    cleanup: error.localizedDescription, path: paths.archive.path)
            }
            throw AuxmoUpdateError.checksumMismatch
        }
        let appBundle: URL
        let extractor = UpdateArchiveExtractor(run: runProcess)
        switch update.archiveKind {
        case .dmg:
            appBundle = try extractor.extractDMG(paths.archive, to: paths.extracted)
        case .zip:
            // 仅为升级安装旧版保留；新建发布和自动更新默认使用 DMG。
            appBundle = try extractor.extractZIP(paths.archive, to: paths.extracted)
        }
        try validateBundle(at: appBundle, expectedVersion: update.version)
        try UpdateArchiveExtractor.removeIfPresent(paths.payload)
        try FileManager.default.moveItem(at: appBundle, to: paths.payload)
        try UpdateArchiveExtractor.removeIfPresent(paths.archive)
        try UpdateArchiveExtractor.removeIfPresent(paths.extracted)
    }

    static func validateReadyInstall(expectedVersion: String) throws {
        guard Bundle.main.bundleIdentifier == "com.colin0v0.auxmo.app" else {
            throw AuxmoUpdateError.developmentBuild
        }
        let paths = currentPaths(version: expectedVersion)
        guard FileManager.default.fileExists(atPath: paths.payload.path) else {
            throw AuxmoUpdateError.readyInstallMissing
        }
        try validateBundle(at: paths.payload, expectedVersion: expectedVersion)
        let helper = helperURL
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw AuxmoUpdateError.helperMissing(helper.path)
        }
    }

    static func launchHelper(expectedVersion: String) throws {
        try validateReadyInstall(expectedVersion: expectedVersion)
        let helper = helperURL
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--pid", "\(ProcessInfo.processInfo.processIdentifier)",
                             "--app", appURL.path,
                             "--stage", stageURL.path,
                             "--version", expectedVersion]
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    static func removeStaging() throws {
        try removeStaging(at: stageURL)
    }

    static func removeStaging(at stage: URL) throws {
        try UpdateArchiveExtractor.requireUnmounted(stage.appendingPathComponent("extracted", isDirectory: true))
        let backup = stage.appendingPathComponent("old", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: backup.path) else {
            throw AuxmoUpdateError.recoveryBackupExists(backup.path)
        }
        if FileManager.default.fileExists(atPath: stage.path) {
            try FileManager.default.removeItem(at: stage)
        }
    }

    static func appendLog(_ message: String) { BoundedUpdateLog.record(message) }

    /// 在替换前验证 Bundle Identifier、版本、可执行文件和代码签名结构。
    static func validateBundle(at appURL: URL, expectedVersion: String) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AuxmoUpdateError.invalidBundle
        }
        let identifier = plist["CFBundleIdentifier"] as? String
        guard identifier == "com.colin0v0.auxmo.app" else {
            throw AuxmoUpdateError.bundleIdentifierMismatch(identifier ?? "缺失")
        }
        let actualVersion = (plist["CFBundleShortVersionString"] as? String) ?? "缺失"
        guard let expected = AuxmoVersionNumber(expectedVersion),
              let actual = AuxmoVersionNumber(actualVersion),
              expected == actual else {
            throw AuxmoUpdateError.bundleVersionMismatch(expected: expectedVersion, actual: actualVersion)
        }
        guard let executable = plist["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(
                atPath: appURL.appendingPathComponent("Contents/MacOS/\(executable)").path) else {
            throw AuxmoUpdateError.invalidBundle
        }
        do {
            _ = try runProcess("/usr/bin/codesign",
                               ["--verify", "--deep", "--strict", "--verbose=2", appURL.path])
        } catch {
            throw AuxmoUpdateError.invalidSignature(error.localizedDescription)
        }
    }

    private static var helperURL: URL {
        appURL.appendingPathComponent("Contents/Helpers/AuxmoUpdateHelper")
    }

    private static func currentPaths(version: String) -> Paths {
        let stage = stageURL
        return Paths(stage: stage,
                     archive: stage.appendingPathComponent("Auxmo-\(version).dmg"),
                     extracted: stage.appendingPathComponent("extracted", isDirectory: true),
                     payload: stage.appendingPathComponent("payload", isDirectory: true),
                     oldBundle: stage.appendingPathComponent("old", isDirectory: true))
    }

    private static func writeMetadata(update: AuxmoAvailableUpdate, paths: Paths) throws {
        let metadata: [String: Any] = [
            "version": update.version,
            "sha256": update.sha256,
            "downloadURL": update.downloadURL.absoluteString
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: paths.stage.appendingPathComponent("metadata.plist"), options: .atomic)
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
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
            throw AuxmoUpdateError.commandFailed(output.isEmpty ? "退出码 \(process.terminationStatus)" : output)
        }
        return output
    }
}
