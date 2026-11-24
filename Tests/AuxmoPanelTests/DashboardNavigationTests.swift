import AppKit
import SwiftUI
import Testing
@testable import Auxmo

/// 验证透明标题栏与 SwiftUI 导航在真实窗口中对齐，切换侧边栏不改变窗口尺寸。
@MainActor
struct DashboardNavigationTests {
    @Test func microphonePageRegistersAndClearsVisibleInputControls() {
        _ = NSApplication.shared
        let hardware = RoutingTestHardware()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false)
        defer { _ = model.shutdown() }
        let selection = DashboardSelection()
        selection.page = .output
        let host = NSHostingView(rootView: MainDashboardView(
            model: model, openApplicationAudioEffects: { _, _, _ in }, selection: selection))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(!model.inputControlsVisibleSurfaces.contains(.controlWindow))

        selection.page = .microphone
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(model.inputControlsVisibleSurfaces.contains(.controlWindow))

        selection.page = .statistics
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(!model.inputControlsVisibleSurfaces.contains(.controlWindow))

        selection.page = .microphone
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.contentView = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(!model.inputControlsVisibleSurfaces.contains(.controlWindow))
    }

    @Test func expandedAndCollapsedNavigationRetainWindowGeometry() throws {
        _ = NSApplication.shared
        let hardware = RoutingTestHardware()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false)
        defer { _ = model.shutdown() }
        let selection = DashboardSelection()
        selection.page = .settings
        let host = DashboardHostingController(rootView: MainDashboardView(
            model: model, openApplicationAudioEffects: { _, _, _ in }, selection: selection))
        host.sizingOptions = []
        let window = AuxmoDashboardWindow(
            contentRect: NSRect(origin: .zero, size: AuxmoDashboardWindow.initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.contentViewController = host
        window.setContentSize(AuxmoDashboardWindow.initialContentSize)
        window.contentMinSize = AuxmoDashboardWindow.minimumContentSize
        defer { window.orderOut(nil); window.contentViewController = nil }

        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        host.view.layoutSubtreeIfNeeded()
        window.layoutWindowControls()
        let button = try #require(window.standardWindowButton(.closeButton))
        let parent = try #require(button.superview)
        let center = host.view.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), from: parent)
        // 标题栏原生按钮必须位于顶部 52pt 导航内，且不覆盖 72pt 之后的侧边栏按钮。
        #expect(center.x > 0 && center.x < 72)
        let expectedY = host.view.isFlipped ? CGFloat(26) : host.view.bounds.height - 26
        #expect(abs(center.y - expectedY) < 1)
        let scroll = try #require(descendants(of: host.view).compactMap { $0 as? NSScrollView }
            .first { $0.verticalScroller is DashboardScroller })
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.borderType == .noBorder)
        #expect(!scroll.drawsBackground)
        try saveView(host.view, to: "/tmp/auxmo-dashboard-expanded.png")

        // 系统首次显示窗口时会避让屏幕边界；以显示后的实际位置验证收纳操作不移动窗口。
        let initialFrame = window.frame
        let expandedUpdatePixels = try updateButtonPixels(in: host.view)
        selection.sidebarVisible = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.view.layoutSubtreeIfNeeded()
        #expect(window.frame == initialFrame)
        #expect(selection.page == .settings)
        // 比较导航右上角的真实渲染，防止收纳时图标或右边距发生位移。
        #expect(try updateButtonPixels(in: host.view) == expandedUpdatePixels)
        try saveView(host.view, to: "/tmp/auxmo-dashboard-collapsed.png")

        selection.sidebarVisible = true
        window.setContentSize(AuxmoDashboardWindow.minimumContentSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.view.layoutSubtreeIfNeeded()
        #expect(window.contentLayoutRect.width >= 900)
        try saveView(host.view, to: "/tmp/auxmo-dashboard-minimum.png")
    }

    private func updateButtonPixels(in view: NSView) throws -> Data {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let scale = CGFloat(image.width) / view.bounds.width
        // 截取固定的窗口右上角，包含 28pt 图标和两侧空白。
        let crop = try #require(image.cropping(to: CGRect(
            x: CGFloat(image.width) - 70 * scale, y: 0, width: 70 * scale, height: 52 * scale)))
        return try #require(NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func saveView(_ view: NSView, to path: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
