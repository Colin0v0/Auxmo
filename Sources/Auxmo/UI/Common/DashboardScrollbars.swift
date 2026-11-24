import AppKit
import SwiftUI

/// 详情页只绘制 3pt 的贴边滑块；仍使用原生滚动条处理拖拽、滚轮与辅助功能。
final class DashboardScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // 轨道保持透明，不绘制系统的白色底板或分隔边。
    }

    override func drawKnob() {
        guard knobProportion < 1 else { return }
        let knob = rect(for: .knob)
        let thinKnob = NSRect(x: bounds.maxX - 3, y: knob.minY, width: 3, height: knob.height)
        NSColor.secondaryLabelColor.withAlphaComponent(0.42).setFill()
        NSBezierPath(roundedRect: thinKnob, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

struct DashboardScrollbars: NSViewRepresentable {
    func makeNSView(context: Context) -> DashboardScrollPolicyView { DashboardScrollPolicyView() }
    func updateNSView(_ view: DashboardScrollPolicyView, context: Context) { view.applyPolicy() }
}

final class DashboardScrollPolicyView: NSView {
    private weak var configuredScroll: NSScrollView?
    private var styleObservation: NSKeyValueObservation?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); applyPolicy() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyPolicy() }
    override func layout() { super.layout(); applyPolicy() }

    func applyPolicy() {
        guard let scroll = enclosingScrollView else { return }
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        if !(scroll.verticalScroller is DashboardScroller) {
            scroll.verticalScroller = DashboardScroller()
        }
        scroll.scrollerStyle = .overlay
        guard configuredScroll !== scroll else { return }
        configuredScroll = scroll
        // 尊重用户系统偏好，不修改全局设置；只固定这一个详情容器的悬浮样式。
        styleObservation = scroll.observe(\.scrollerStyle, options: [.new]) { scroll, _ in
            MainActor.assumeIsolated {
                if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            }
        }
    }
}
