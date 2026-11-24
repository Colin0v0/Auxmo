/// 顶部唯一导航层：输出与麦克风保留同一套 APP 播放控制，耳机功能单独成页。
enum AudioPanelPage: CaseIterable, Hashable {
    case output, microphone, headphones, statistics

    var title: String {
        title(language: .chinese)
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .output: return L10n.text("输出", language: language)
        case .microphone: return L10n.text("麦克风", language: language)
        case .headphones: return L10n.text("耳机控制", language: language)
        case .statistics: return L10n.text("统计", language: language)
        }
    }

    var displaysApplications: Bool { self == .output || self == .microphone }

    /// 轻量面板只承载即时控制；统计详情属于完整主窗口，不在窄浮层中展示。
    static func available(showHeadphoneControls: Bool) -> [AudioPanelPage] {
        allCases.filter { page in
            page != .statistics && (showHeadphoneControls || page != .headphones)
        }
    }
}
