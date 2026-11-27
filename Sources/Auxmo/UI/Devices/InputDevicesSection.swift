import SwiftUI
import AuxmoCore

/// 麦克风与输出设备分别保存隐藏状态；隐藏不会改动系统默认输入或麦克风音量。
struct InputDevicesSection: View {
    let audio: SystemInputSnapshot
    let select: (AudioInput) -> Void
    let setVolume: (Float, AudioInput) -> Void
    let setMuted: (Bool, AudioInput) -> Void
    @Environment(\.appLanguage) private var language
    @Environment(\.dashboardLayout) private var dashboardLayout
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            if let hidden = settings.hiddenInputs {
                if audio.inputs.isEmpty {
                    Label(L10n.text("暂无可用麦克风", language: language), systemImage: "mic.slash")
                        .foregroundStyle(PanelStyle.secondary).frame(maxWidth: .infinity).padding(.vertical, 20)
                }
                // 已隐藏设备被系统外部设为默认时仍显示，并禁止再次隐藏。
                let activeUIDs = Set(audio.inputs.filter { $0.id == audio.selectedID }.map(\.uid))
                ForEach(Self.visibleInputs(audio.inputs, hiddenUIDs: Set(hidden.keys), selectedID: audio.selectedID)) { input in
                    if let control = audio.controls[input.id] {
                        AudioDeviceRow(device: input, control: control, selected: input.id == audio.selectedID,
                                       select: { select(input) }, setVolume: { setVolume($0, input) },
                                       setMuted: { setMuted($0, input) })
                            .contextMenu {
                                Button(L10n.text("隐藏设备", language: language)) {
                                    guard input.id != audio.selectedID else { return }
                                    settings.hideInput(uid: input.uid, name: input.name)
                                }
                                .disabled(input.id == audio.selectedID)
                            }
                    } else {
                        PanelError(text: L10n.format("%@ 尚未读取输入控制状态", language: language,
                                                     arguments: [input.name])).padding(12)
                    }
                }
                let inactiveHidden = hidden.filter { !activeUIDs.contains($0.key) }
                // 麦克风恢复入口与输出一致，只显示在完整窗口。
                if dashboardLayout && !inactiveHidden.isEmpty {
                    hiddenDevices(inactiveHidden)
                }
            } else {
                // 配置损坏时不猜测隐藏列表，也不覆盖原始数据。
                PanelError(text: L10n.text("已隐藏麦克风设置无法读取", language: language))
                    .padding(.horizontal, dashboardLayout ? 0 : PanelMetrics.horizontalInset)
            }
        }
    }

    static func visibleInputs(_ inputs: [AudioInput], hiddenUIDs: Set<String>, selectedID: UInt32?) -> [AudioInput] {
        inputs.filter { !hiddenUIDs.contains($0.uid) || $0.id == selectedID }
    }

    private func hiddenDevices(_ entries: [String: String]) -> some View {
        HiddenDevicesDisclosure(
            title: L10n.text("已隐藏麦克风", language: language),
            entries: entries,
            icon: "eye.slash",
            itemIcon: "mic",
            horizontalInset: dashboardLayout ? 0 : PanelMetrics.horizontalInset,
            restore: settings.restoreInput
        )
    }
}
