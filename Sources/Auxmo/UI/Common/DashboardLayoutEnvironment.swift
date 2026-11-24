import SwiftUI

/// 完整窗口以导航栏左边缘作为公共对齐线；菜单栏浮层继续使用原有行内留白。
private struct DashboardLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dashboardLayout: Bool {
        get { self[DashboardLayoutKey.self] }
        set { self[DashboardLayoutKey.self] = newValue }
    }
}
