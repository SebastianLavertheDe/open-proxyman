import SwiftUI

struct TrafficDiffView: View {
    let left: Transaction
    let right: Transaction
    @Environment(\.dismiss) private var dismiss
    @State private var unified = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("响应对比").font(.headline)
                Spacer()
                Picker("显示", selection: $unified) {
                    Text("并排").tag(false)
                    Text("统一").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if unified {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.enumerated()), id: \.offset) { _, line in
                            Text(line.text)
                                .foregroundStyle(line.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
            } else {
                HSplitView {
                    panel(left, title: "原响应")
                    panel(right, title: "对照响应")
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
        .padding()
        .frame(width: 780, height: 520)
    }

    private func panel(_ tx: Transaction, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title + " · " + tx.fullURL).lineLimit(1).help(tx.fullURL)
            ScrollView {
                Text(lines(tx).joined(separator: "\n"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .frame(minWidth: 260)
    }

    private func lines(_ tx: Transaction) -> [String] {
        let prefix = tx.responseBody.prefix(65536)
        let body = String(data: prefix, encoding: .utf8) ?? prefix.map { String(format: "%02x", $0) }.joined(separator: " ")
        var lines = ["\(tx.responseVersion) \(tx.statusText)"]
        lines += tx.responseHeaders.pairs.map { "\($0.name): \($0.value)" }
        lines += [""]
        lines += Array(body.components(separatedBy: .newlines).prefix(400))
        if tx.responseBody.count > 65536 || body.components(separatedBy: .newlines).count > 400 || tx.responseTruncated {
            lines.append("… 正文仅显示部分内容")
        }
        return lines
    }

    private var diff: [(text: String, color: Color)] {
        let before = lines(left)
        let after = lines(right)
        let differences = after.difference(from: before)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in differences {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var i = 0
        var j = 0
        var result: [(String, Color)] = []
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                result.append(("- " + before[i], .red))
                i += 1
            } else if j < after.count, inserted.contains(j) {
                result.append(("+ " + after[j], .green))
                j += 1
            } else if i < before.count, j < after.count {
                result.append(("  " + before[i], .primary))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return result
    }
}
