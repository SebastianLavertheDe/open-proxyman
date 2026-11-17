import Foundation
@testable import ProxyMirrorCore

@MainActor
func runUIPerformanceChecks() {
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-saved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedFile = directory.appendingPathComponent("Saved.proxymirror")
        let folderFile = directory.appendingPathComponent("SourceFolders.json")
        let old = Transaction()
        old.comment = "existing"
        try SessionFile(transactions: [old], pinnedDomains: [], selected: []).write(to: savedFile)

        let store = TrafficStore(sourceFolderFile: folderFile, savedFile: savedFile)
        let second = TrafficStore(sharing: store)
        second.followLatest = true
        let captured = Transaction()
        store.add(captured)
        store.selectManually([captured.id])
        store.saveSelection()
        check(waitForSaved(store) == true, "Saved: 等待加载并落盘启动期间的新增收藏")
        let saved = try SessionFile.decode(Data(contentsOf: savedFile))
        eq(Set(saved.records.map(\.id)), [old.id, captured.id], "Saved: 启动期间收藏时保留磁盘已有记录")
        eq(second.saved.count, 2, "Saved: 工作区共享加载结果")

        for record in store.saved { record.comment = "batch" }
        store.update(store.saved)
        for record in store.saved { record.comment = "last write" }
        store.update(store.saved)
        check(waitForSaved(store) == true, "Saved: 等待顺序持久化批量修改")
        let latest = try SessionFile.decode(Data(contentsOf: savedFile))
        check(latest.records.allSatisfy { $0.comment == "last write" }, "Saved: 最后一次批量操作最终落盘")

        let broken = directory.appendingPathComponent("Broken.proxymirror")
        let original = Data("Invalid session".utf8)
        try original.write(to: broken)
        let invalid = TrafficStore(sourceFolderFile: folderFile, savedFile: broken)
        let pending = Transaction()
        invalid.add(pending)
        invalid.selectManually([pending.id])
        invalid.saveSelection()
        check(waitForSaved(invalid) == false, "Saved: 加载损坏文件时报告错误")
        eq(try Data(contentsOf: broken), original, "Saved: 不覆写加载失败的收藏文件")

        second.setWorkspaceVisible(false)
        let next = Transaction()
        store.add(next)
        eq(second.selectedID, captured.id, "工作区: 隐藏时不重新选择")
        second.setWorkspaceVisible(true)
        eq(second.selectedID, next.id, "工作区: 重新显示时追上最新流量")

        let tx = Transaction()
        let column = CustomTrafficColumn(title: "rank", source: .responseJSON, key: "rank")
        tx.responseBody = Data(#"{"rank":1}"#.utf8)
        eq(column.value(for: tx), "1", "自定义列: 首次读取 JSON")
        tx.responseBody = Data(#"{"rank":2}"#.utf8)
        eq(column.value(for: tx), "2", "自定义列: 相同长度的正文替换使缓存失效")
        let other = Transaction(id: tx.id)
        other.responseBody = Data(#"{"rank":3}"#.utf8)
        eq(column.value(for: other), "3", "自定义列: 相同 ID 的会话副本独立缓存")

        var scanner = GRPCFrames.Scanner()
        let first = Data([0, 0, 0, 0, 1, 65])
        let secondFrame = Data([0, 0, 0, 0, 2, 66, 67])
        let initialScan = scanner.scan(first, complete: false, truncated: false)
        let partial = scanner.scan(first + secondFrame.dropLast(), complete: false, truncated: false)
        let complete = scanner.scan(first + secondFrame, complete: true, truncated: false)
        eq(partial.messages, initialScan.messages, "gRPC: 增量扫描保留已完整的消息")
        eq(complete.messages.map(\.id), [0, first.count], "gRPC: 追加后继续扫描下一条消息")
        eq(complete.issue, nil, "gRPC: 完整后清除未完成提示")

        let body = Data(("[" + Array(repeating: "0", count: 5000).joined(separator: ",") + "]").utf8)
        let tree = JSONTreeService.build(from: body)
        eq(tree?.children.count, JSONTreeService.maxNodes - 1, "JSON 树: 大数组子项受节点预算约束")
        eq(tree?.childCount, 5000, "JSON 树: 保留实际子项总数")
        checkBodyPreview()
    } catch {
        check(false, "UI 性能回归自测：\(error.localizedDescription)")
    }
}

private func checkBodyPreview() {
    let textPageSize = BodyPreviewRenderer.Format.text.pageSize
    let textPrefix = String(repeating: "a", count: textPageSize - 1)
    let text = Data((textPrefix + "😀末尾").utf8)
    let firstPage = BodyPreviewRenderer.render(text, format: .text, page: 0)
    let secondPage = BodyPreviewRenderer.render(text, format: .text, page: 1)
    check(firstPage == textPrefix && secondPage == "😀末尾", "Raw: UTF-8 字符跨页时完整显示")
    eq(BodyPreviewRenderer.range(in: text + Data("追加".utf8), format: .text, page: 0),
       BodyPreviewRenderer.range(in: text, format: .text, page: 0), "Raw: 追加正文时保留已填满的页")
    let longText = Data(repeating: 65, count: BodyPreviewRenderer.textLimit + 32)
    eq(BodyPreviewRenderer.pageCount(bytes: longText.count, format: .text),
       BodyPreviewRenderer.textLimit / textPageSize, "Raw: 分页遵守预览上限")
    eq(BodyPreviewRenderer.renderAll(longText, format: .text)?.utf8.count,
       BodyPreviewRenderer.textLimit, "Raw: 复制完整的可预览正文")

    let rawHead = RawMessageHead(startLine: "HTTP/1.1 200 OK", headers: HTTPHeaders([("X-Test", "yes")]))
    eq(rawHead.text + "body", "HTTP/1.1 200 OK\r\nX-Test: yes\r\n\r\nbody", "Raw: 复制时保留报文换行和头部分隔符")

    let binary = Data([88, 65, 0, 127])
    eq(BodyPreviewRenderer.render(binary.dropFirst(), format: .hex, page: 0),
       "00000000  41 00 7f" + String(repeating: " ", count: 41) + "|A..|",
       "Hex: 支持非零起始索引及不足 16 字节的末行")
    let hexPageSize = BodyPreviewRenderer.Format.hex.pageSize
    let pagedBinary = Data(repeating: 65, count: hexPageSize) + Data([66])
    check(BodyPreviewRenderer.render(pagedBinary, format: .hex, page: 1)?.hasPrefix("00001000  42") == true,
          "Hex: 后续页保留正文中的真实偏移")
    eq(BodyPreviewRenderer.range(in: pagedBinary, format: .hex, page: 0),
       BodyPreviewRenderer.range(in: pagedBinary.prefix(hexPageSize), format: .hex, page: 0),
       "Hex: 追加正文时保留已填满的页")
}

@MainActor
private func waitForSaved(_ store: TrafficStore) -> Bool? {
    var outcome: Bool?
    guard store.finishSaving({ outcome = $0 }) else { return true }
    let deadline = Date().addingTimeInterval(5)
    while outcome == nil && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return outcome
}
