import SwiftUI

/// 主窗口聚焦时才启用 Flow 动作，避免规则窗口或编辑弹窗误操作流量。
private struct TrafficCommandsActiveKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var trafficCommandsActive: Bool? {
        get { self[TrafficCommandsActiveKey.self] }
        set { self[TrafficCommandsActiveKey.self] = newValue }
    }
}
