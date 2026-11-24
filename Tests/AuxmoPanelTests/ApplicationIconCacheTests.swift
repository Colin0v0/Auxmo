import AppKit
import Testing
@testable import Auxmo

@MainActor
struct ApplicationIconCacheTests {
    @Test func historicalIdentityLoadsInstalledApplicationIcon() throws {
        // Finder 随 macOS 安装；通过统计页使用的身份格式定位，而非依赖它当前是否运行。
        let url = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
        let image = try #require(ApplicationIconCache.icon(forApplicationIdentity: "bundle:com.apple.finder"))
        #expect(image === ApplicationIconCache.icon(for: url))
        #expect(image === ApplicationIconCache.icon(forApplicationIdentity: "bundle:com.apple.finder"))
        #expect(!image.representations.isEmpty)
    }

    @Test func unavailableApplicationHasNoSubstituteIcon() {
        #expect(ApplicationIconCache.icon(forApplicationIdentity: "pid:123") == nil)
        #expect(ApplicationIconCache.icon(forApplicationIdentity: "bundle:") == nil)
        #expect(ApplicationIconCache.icon(forApplicationIdentity: "com.apple.finder") == nil)
        #expect(ApplicationIconCache.icon(forApplicationIdentity: "bundle:com.auxmo.uninstalled.\(UUID().uuidString)") == nil)
    }
}
