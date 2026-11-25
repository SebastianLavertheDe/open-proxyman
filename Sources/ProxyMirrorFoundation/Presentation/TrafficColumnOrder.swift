import Foundation

/// 合并当前可见列的拖拽顺序，同时保留隐藏列在完整顺序中的位置。
public enum TrafficColumnOrder {
    public static func merging(visibleOrder: [String], previousOrder: [String]) -> [String] {
        var seen = Set<String>()
        let visible = visibleOrder.filter { seen.insert($0).inserted }
        let visibleIDs = Set(visible)
        seen.removeAll()
        let previous = previousOrder.filter { seen.insert($0).inserted }
        var remaining = visible.makeIterator()
        var result = previous.map { visibleIDs.contains($0) ? remaining.next() ?? $0 : $0 }
        result.append(contentsOf: remaining)
        return result
    }
}
