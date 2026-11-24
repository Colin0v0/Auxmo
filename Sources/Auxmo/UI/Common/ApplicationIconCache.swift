import AppKit

/// 混音列表与统计页共用真实应用图标，避免采样刷新时反复读取应用包。
@MainActor
enum ApplicationIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }

    /// 统计记录保存的是「bundle:标识符」；历史记录不需要应用仍在运行。
    /// 仅有进程号或应用已卸载时没有可读取的应用包，明确返回空值，不替换成其他图标。
    static func icon(forApplicationIdentity identity: String) -> NSImage? {
        guard identity.hasPrefix("bundle:") else { return nil }
        let bundleID = String(identity.dropFirst("bundle:".count))
        guard !bundleID.isEmpty else { return nil }
        let key = identity as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let image = icon(for: url)
        cache.setObject(image, forKey: key)
        return image
    }
}
