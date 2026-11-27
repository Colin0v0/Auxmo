import SwiftUI

@MainActor
private final class HiddenDevicesDisclosureState: ObservableObject {
    @Published var expanded: Bool

    init(expanded: Bool) {
        self.expanded = expanded
    }
}

/// 输入和输出共用同一套隐藏设备展开行，图标、文字和箭头始终与普通设备行对齐。
struct HiddenDevicesDisclosure: View {
    let title: String
    let entries: [String: String]
    let icon: String
    let itemIcon: String
    let horizontalInset: CGFloat
    let restore: (String) -> Void
    @Environment(\.appLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var disclosure: HiddenDevicesDisclosureState
    @StateObject private var hover = PanelRowHoverState()

    init(title: String, entries: [String: String], icon: String, itemIcon: String,
         horizontalInset: CGFloat, initiallyExpanded: Bool = false,
         restore: @escaping (String) -> Void) {
        self.title = title
        self.entries = entries
        self.icon = icon
        self.itemIcon = itemIcon
        self.horizontalInset = horizontalInset
        self.restore = restore
        _disclosure = StateObject(wrappedValue: HiddenDevicesDisclosureState(expanded: initiallyExpanded))
    }

    /// 单台设备不显示数量；两台以上才跟多设备输出一样显示数量和单位。
    static func displayTitle(_ title: String, count: Int, language: AppLanguage) -> String {
        guard count > 1 else { return title }
        return L10n.format("%@ · %d 台", language: language, arguments: [title, count])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // 内容与多设备输出一样立即切换，只有箭头做短旋转动画。
                disclosure.expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    AudioDeviceIcon(symbol: icon, selected: false, highlighted: hover.active)
                    Text(Self.displayTitle(title, count: entries.count, language: language))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(disclosure.expanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: disclosure.expanded)
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .font(PanelStyle.bodyFont)
                .foregroundStyle(PanelStyle.secondary)
                .frame(maxWidth: .infinity, minHeight: PanelMetrics.deviceRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover.active = $0 }
            .panelContentHover(hover.active)
            .accessibilityLabel(Self.displayTitle(title, count: entries.count, language: language))
            .accessibilityHint(L10n.text(disclosure.expanded ? "收起已隐藏设备" : "展开已隐藏设备", language: language))

            if disclosure.expanded {
                ForEach(entries.keys.sorted(), id: \.self) { uid in
                    HStack(spacing: 8) {
                        AudioDeviceIcon(symbol: itemIcon, selected: false)
                        Text(entries[uid]!).lineLimit(1).help(uid)
                        Spacer(minLength: 4)
                        Button(L10n.text("恢复", language: language)) { restore(uid) }
                            .buttonStyle(PanelButtonStyle())
                    }
                    .font(PanelStyle.bodyFont)
                    .foregroundStyle(PanelStyle.secondary)
                    .frame(minHeight: PanelMetrics.deviceRowHeight)
                }
            }
        }
        .padding(.horizontal, horizontalInset)
    }
}
