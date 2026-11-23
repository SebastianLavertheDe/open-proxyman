import SwiftUI
import AppKit
import Darwin

@MainActor
struct TrafficDiffWorkspaceView: View {
    @ObservedObject var appState: AppState
    @State private var leftID: UUID?
    @State private var rightID: UUID?

    private var pool: [Transaction] { appState.diffPool }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("对比池（\(pool.count)）").font(.headline)
                    Spacer()
                    Button { addSelection() } label: { Image(systemName: "plus") }
                        .help("将主窗口选中的请求加入对比池")
                }.padding(.horizontal, 10)
                List(pool) { transaction in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("#\(transaction.seq) \(transaction.method)").font(.caption).foregroundStyle(.secondary)
                        Text(transaction.fullURL).lineLimit(2).help(transaction.fullURL)
                        HStack {
                            Button("左侧") { leftID = transaction.id }.tint(leftID == transaction.id ? .accentColor : .secondary)
                            Button("右侧") { rightID = transaction.id }.tint(rightID == transaction.id ? .accentColor : .secondary)
                            Spacer()
                            if appState.diffPool.contains(where: { $0.id == transaction.id }) {
                                Button { appState.toggleDiffCandidate(transaction) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("从对比池移除")
                            }
                        }
                    }.padding(.vertical, 3)
                }
                Button("清空对比池") { appState.clearDiffPool() }.padding(.horizontal, 10)
            }.padding(.vertical, 10).frame(minWidth: 210, idealWidth: 250, maxWidth: 360)
            VStack(spacing: 0) {
                HStack {
                    selector("左侧", selection: $leftID)
                    Button { swap(&leftID, &rightID) } label: { Image(systemName: "arrow.left.arrow.right") }
                    selector("右侧", selection: $rightID)
                }.padding(10)
                Divider()
                if let left = pool.first(where: { $0.id == leftID }), let right = pool.first(where: { $0.id == rightID }) {
                    TrafficDiffView(left: left, right: right, showsClose: false)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.on.doc").font(.largeTitle)
                        Text("将请求加入对比池，并分别指定左侧和右侧。")
                        Button("加入主窗口选择") { addSelection(); seedSelection() }
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minWidth: 620)
        }
        .frame(minWidth: 900, idealWidth: 1150, minHeight: 540, idealHeight: 720)
        .onAppear { adoptTargets() }
        .onChange(of: appState.diffTargets.map(\.id)) { _ in adoptTargets() }
    }

    private func selector(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("选择请求").tag(nil as UUID?)
            ForEach(pool) { transaction in
                Text("#\(transaction.seq) \(transaction.method) \(transaction.fullURL)").tag(Optional(transaction.id))
            }
        }
    }

    private func addSelection() {
        for transaction in appState.activeStore.selectedTransactions
            where !appState.diffPool.contains(where: { $0.id == transaction.id }) {
            appState.toggleDiffCandidate(transaction)
        }
    }

    private func adoptTargets() {
        for transaction in appState.diffTargets
            where !appState.diffPool.contains(where: { $0.id == transaction.id }) {
            appState.toggleDiffCandidate(transaction)
        }
        seedSelection()
    }

    private func seedSelection() {
        let candidates = appState.diffTargets.isEmpty ? pool : appState.diffTargets
        if candidates.count >= 2 {
            leftID = candidates[0].id
            rightID = candidates[1].id
        }
    }
}

@MainActor
struct TrafficDiffView: View {
    @ObservedObject var left: Transaction
    @ObservedObject var right: Transaction
    var showsClose = true
    @Environment(\.dismiss) private var dismiss
    @State private var unified = false
    @State private var component = TrafficDiffDocument.Component.response
    @State private var sortJSON = true
    @State private var sortHeaders = true
    @State private var wordChanges = true
    @State private var comparison: TrafficDiffDocument.Result?
    @State private var externalError: String?

    private var leftLines: [String] { TrafficDiffDocument.lines(left, component: component, sortJSON: sortJSON, sortHeaders: sortHeaders) }
    private var rightLines: [String] { TrafficDiffDocument.lines(right, component: component, sortJSON: sortJSON, sortHeaders: sortHeaders) }
    private var input: DiffInput { DiffInput(before: leftLines, after: rightLines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("内容", selection: $component) {
                    ForEach(TrafficDiffDocument.Component.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 180)
                Picker("显示", selection: $unified) {
                    Text("并排").tag(false)
                    Text("统一").tag(true)
                }.pickerStyle(.segmented).frame(width: 140)
                Spacer()
                Menu("外部对比") {
                    Button("FileMerge") { openExternal("FileMerge") }
                    Button("Kaleidoscope") { openExternal("Kaleidoscope") }
                }
                if showsClose { Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            HStack {
                Toggle("JSON 键排序", isOn: $sortJSON)
                Toggle("Header 排序", isOn: $sortHeaders)
                Toggle("词级差异", isOn: $wordChanges)
                Spacer()
                if let comparison {
                    Text("+\(comparison.inserted) / −\(comparison.removed)").foregroundStyle(.secondary)
                }
            }.toggleStyle(.checkbox)
            HStack {
                Text("← \(left.method) \(left.fullURL)").lineLimit(1).help(left.fullURL)
                Spacer()
                Text("\(right.method) \(right.fullURL) →").lineLimit(1).help(right.fullURL)
            }.font(.caption).foregroundStyle(.secondary)
            Divider()
            if let comparison {
                ScrollView([.horizontal, .vertical]) {
                    if unified {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(comparison.unified.enumerated()), id: \.offset) { _, line in
                                Text(prefix(line.change) + line.text)
                                    .foregroundStyle(line.change == .removed ? Color.red : line.change == .inserted ? .green : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 1)
                            }
                        }.padding(8)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(comparison.pairs.enumerated()), id: \.offset) { _, pair in
                                HStack(alignment: .top, spacing: 0) {
                                    diffCell(pair.left, other: pair.right, number: pair.leftNumber, removed: true, changed: pair.changed)
                                    Divider()
                                    diffCell(pair.right, other: pair.left, number: pair.rightNumber, removed: false, changed: pair.changed)
                                }
                            }
                        }
                    }
                }.textSelection(.enabled)
            } else {
                ProgressView("正在比较…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("正文最多 256 KiB / 1200 行；压缩正文使用解码后的内容，二进制使用十六进制。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(12)
        .frame(minWidth: 700, minHeight: 440)
        .task(id: input) {
            let captured = input
            let result = await Task.detached(priority: .userInitiated) {
                TrafficDiffDocument.compare(captured.before, captured.after)
            }.value
            if !Task.isCancelled { comparison = result }
        }
        .alert("外部对比失败", isPresented: Binding(get: { externalError != nil }, set: { if !$0 { externalError = nil } })) {
            Button("好") { externalError = nil }
        } message: { Text(externalError ?? "") }
    }

    private func prefix(_ change: TrafficDiffDocument.Change) -> String {
        switch change { case .equal: return "  "; case .removed: return "− "; case .inserted: return "+ " }
    }

    private func diffCell(_ text: String?, other: String?, number: Int?, removed: Bool, changed: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number.map(String.init) ?? "").foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            highlighted(text ?? "", other: other ?? "", removed: removed, changed: changed)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .frame(minWidth: 350, maxWidth: .infinity, alignment: .leading)
        .background(changed ? (removed ? Color.red : Color.green).opacity(text == nil ? 0.04 : 0.12) : .clear)
    }

    private func highlighted(_ text: String, other: String, removed: Bool, changed: Bool) -> Text {
        guard wordChanges, changed, text.count < 4096, other.count < 4096 else { return Text(text) }
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let otherWords = other.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let difference = words.difference(from: otherWords)
        var changes = Set<Int>()
        for change in difference {
            if case .insert(let index, _, _) = change { changes.insert(index) }
        }
        return words.enumerated().reduce(Text("")) { result, item in
            let token = Text((item.offset == 0 ? "" : " ") + item.element)
            return result + (changes.contains(item.offset) ? token.foregroundColor(removed ? .red : .green).bold() : token)
        }
    }

    private func openExternal(_ application: String) {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirror-Diff", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var information = stat()
            guard lstat(directory.path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR,
                  information.st_uid == geteuid() else {
                throw NSError(domain: "TrafficDiff", code: 2, userInfo: [NSLocalizedDescriptionKey: "外部对比临时目录必须由当前用户拥有，且不能是符号链接。"])
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            // open(1) returns before the target application reads the files. Keep them until the next day's cleanup.
            let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in contents {
                if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(date) > 86_400 { try? FileManager.default.removeItem(at: file) }
            }
            let identifier = UUID().uuidString
            let before = directory.appendingPathComponent(identifier + "-left.txt")
            let after = directory.appendingPathComponent(identifier + "-right.txt")
            try PrivateAppFile.write(Data(leftLines.joined(separator: "\n").utf8), to: before)
            try PrivateAppFile.write(Data(rightLines.joined(separator: "\n").utf8), to: after)
            let process = Process()
            if application == "FileMerge" {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/opendiff")
                process.arguments = [before.path, after.path]
            } else {
                guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.blackpixel.kaleidoscope") != nil else {
                    throw NSError(domain: "TrafficDiff", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先安装 Kaleidoscope。"])
                }
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", application, before.path, after.path]
            }
            process.terminationHandler = { task in
                if task.terminationStatus != 0 {
                    Task { @MainActor in externalError = "\(application) 退出码 \(task.terminationStatus)。FileMerge 需要安装 Xcode Command Line Tools。" }
                }
            }
            try process.run()
        } catch { externalError = error.localizedDescription }
    }

    private struct DiffInput: Hashable, Sendable { let before: [String]; let after: [String] }
}
