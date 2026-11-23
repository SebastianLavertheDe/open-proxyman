import SwiftUI

@MainActor
struct ProtobufRulesView: View {
    @ObservedObject private var store = ProtobufRuleStore.shared
    @State private var importing = false
    @State private var editing: ProtobufMappingRule?
    @State private var selectedTab = 0
    @State private var converterInput = ""
    @State private var converterOutput = ""
    @State private var converterSchema: UUID?
    @State private var converterMessage = ""
    @State private var converterEncoding = ProtobufPayloadEncoding.single
    @State private var converterBase64 = true
    @State private var converterBusy = false
    @State private var errorsOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Protobuf").font(.headline)
                Spacer()
                Toggle("启用映射", isOn: Binding(get: { store.configuration.enabled }, set: { enabled in
                    var next = store.configuration; next.enabled = enabled
                    save(next)
                }))
            }
            TabView(selection: $selectedTab) {
                schemas.tabItem { Text("Schema") }.tag(0)
                mappings.tabItem { Text("消息映射") }.tag(1)
                converter.tabItem { Text("Converter") }.tag(2)
                console.tabItem { Text("Console") }.tag(3)
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(16).frame(minWidth: 740, idealWidth: 820, minHeight: 480, idealHeight: 560)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): store.importSchema(url)
            case .failure(let error): store.fail(error)
            }
        }
        .sheet(item: $editing) { rule in
            ProtobufMappingEditor(rule: rule) { replacement in
                var next = store.configuration
                if let index = next.rules.firstIndex(where: { $0.id == replacement.id }) { next.rules[index] = replacement }
                else { next.rules.append(replacement) }
                do { try store.save(next); editing = nil } catch { store.fail(error) }
            }
        }
    }

    private var schemas: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("导入 .desc / .pb…") { importing = true }.disabled(store.loading)
                if store.loading { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(store.configuration.schemas.count) 个 Schema").foregroundStyle(.secondary)
            }
            Text("使用 protoc --descriptor_set_out=service.desc --include_imports service.proto 生成描述符。导入后复制到本机应用数据目录。")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            List {
                ForEach(store.configuration.schemas) { record in
                    HStack {
                        Toggle(record.name, isOn: Binding(get: { record.enabled }, set: { enabled in
                            var next = store.configuration
                            if let index = next.schemas.firstIndex(where: { $0.id == record.id }) { next.schemas[index].enabled = enabled }
                            save(next)
                        }))
                        Spacer()
                        Text("\(store.schemaNames(id: record.id).count) 个类型").font(.caption).foregroundStyle(.secondary)
                        Button("移除") { do { try store.removeSchema(record.id) } catch { store.fail(error) } }
                    }
                    DisclosureGroup("消息类型") {
                        Text(store.schemaNames(id: record.id).joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }.padding(12)
    }

    private var mappings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("新增映射") {
                    var rule = ProtobufMappingRule(); rule.schemaID = store.configuration.schemas.first?.id; editing = rule
                }
                Spacer()
                Text("按顺序使用第一条匹配规则").font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(store.configuration.rules) { rule in
                    HStack {
                        Toggle("", isOn: Binding(get: { rule.enabled }, set: { enabled in
                            var next = store.configuration
                            if let index = next.rules.firstIndex(where: { $0.id == rule.id }) { next.rules[index].enabled = enabled }
                            save(next)
                        })).labelsHidden()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.name)
                            Text(rule.pattern).font(.caption).foregroundStyle(.secondary)
                            Text("请求: \(rule.requestMessage.isEmpty ? "字段编号" : rule.requestMessage) · \(rule.requestEncoding.rawValue)\n响应: \(rule.responseMessage.isEmpty ? "字段编号" : rule.responseMessage) · \(rule.responseEncoding.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("编辑") { editing = rule }
                        Button("删除") {
                            var next = store.configuration; next.rules.removeAll { $0.id == rule.id }; save(next)
                        }
                    }
                }
                .onMove { indices, destination in
                    var next = store.configuration; next.rules.move(fromOffsets: indices, toOffset: destination); save(next)
                }
            }
        }.padding(12)
    }

    private var converter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Schema", selection: $converterSchema) {
                    Text("无 Schema").tag(nil as UUID?)
                    ForEach(store.configuration.schemas) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("完整消息类型（可选）", text: $converterMessage)
            }
            HStack {
                Toggle("输入为 Base64", isOn: $converterBase64)
                Picker("编码", selection: $converterEncoding) {
                    ForEach(ProtobufPayloadEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 210)
                Spacer()
                Button("解码") { convert() }.disabled(converterBusy || converterInput.isEmpty)
                if converterBusy { ProgressView().controlSize(.small) }
            }
            Text("关闭 Base64 时输入十六进制字节。Delimited 使用 varint 长度前缀。")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                TextEditor(text: $converterInput).font(.system(.body, design: .monospaced))
                ScrollView {
                    Text(converterOutput).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(6)
                }
            }
        }.padding(12)
    }

    private var console: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("仅错误", isOn: $errorsOnly)
                Spacer()
                Button("清空") { store.clearConsole() }
            }
            ScrollViewReader { proxy in
                List(store.console.filter { !errorsOnly || $0.isError }) { entry in
                    HStack(alignment: .top) {
                        Text(entry.date, style: .time).foregroundStyle(.secondary)
                        Text(entry.isError ? "ERROR" : "INFO").foregroundStyle(entry.isError ? Color.red : Color.secondary)
                        Text(entry.message).textSelection(.enabled)
                    }.font(.system(.caption, design: .monospaced)).id(entry.id)
                }
                .onChange(of: store.console.count) { _ in
                    if let id = store.console.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }.padding(12)
    }

    private func save(_ configuration: ProtobufConfiguration) {
        do { try store.save(configuration); store.error = nil } catch { store.fail(error) }
    }

    private func convert() {
        let input = converterInput
        let base64 = converterBase64
        let encoding = converterEncoding
        let schema = store.schema(id: converterSchema)
        let type = converterMessage
        converterBusy = true
        Task {
            defer { converterBusy = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> String in
                    guard input.utf8.count <= GRPCFrames.maxPayload * 4 else { throw GRPCInspectionError("转换输入过大。") }
                    let bytes: Data
                    if base64 {
                        guard let decoded = Data(base64Encoded: input.filter { !$0.isWhitespace }) else { throw GRPCInspectionError("Base64 输入无效。") }
                        bytes = decoded
                    } else {
                        let compact = input.filter { !$0.isWhitespace }
                        guard compact.count % 2 == 0, compact.allSatisfy({ $0.isHexDigit }) else { throw GRPCInspectionError("十六进制输入无效。") }
                        let chars = Array(compact)
                        var decoded = Data()
                        for index in stride(from: 0, to: chars.count, by: 2) {
                            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { throw GRPCInspectionError("十六进制输入无效。") }
                            decoded.append(byte)
                        }
                        bytes = decoded
                    }
                    if !type.isEmpty, schema?.contains(type) != true { throw GRPCInspectionError("请选择包含该消息类型的 Schema。") }
                    let messages = try ProtobufPayload.messages(bytes, encoding: encoding)
                    return try ProtobufPayload.describeMessages(messages, type: type.isEmpty ? nil : type, schema: schema)
                }.value
                converterOutput = result
                store.log("Converter 解码成功。")
            } catch { converterOutput = error.localizedDescription; store.fail(error) }
        }
    }
}

@MainActor
private struct ProtobufMappingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ProtobufRuleStore.shared
    @State var rule: ProtobufMappingRule
    let onSave: (ProtobufMappingRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Protobuf 消息映射").font(.headline)
            TextField("名称", text: $rule.name)
            TextField("完整 URL 或路径通配符", text: $rule.pattern)
            Picker("Schema", selection: $rule.schemaID) {
                Text("请选择").tag(nil as UUID?)
                ForEach(store.configuration.schemas) { Text($0.name).tag(Optional($0.id)) }
            }
            Group {
                messageField("请求消息", $rule.requestMessage)
                encodingPicker("请求编码", $rule.requestEncoding)
                messageField("响应消息", $rule.responseMessage)
                encodingPicker("响应编码", $rule.responseEncoding)
            }
            Picker("正文类型", selection: $rule.payloadType) {
                ForEach(ProtobufPayloadType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { onSave(rule) }.keyboardShortcut(.defaultAction).disabled(rule.schemaID == nil || rule.name.isEmpty)
            }
        }.padding(20).frame(width: 560)
    }

    private func messageField(_ label: String, _ value: Binding<String>) -> some View {
        HStack {
            TextField(label, text: value)
            Menu("选择") {
                Button("按字段编号") { value.wrappedValue = "" }
                ForEach(store.schemaNames(id: rule.schemaID), id: \.self) { type in Button(type) { value.wrappedValue = type } }
            }.fixedSize()
        }
    }

    private func encodingPicker(_ label: String, _ value: Binding<ProtobufPayloadEncoding>) -> some View {
        Picker(label, selection: value) {
            ForEach(ProtobufPayloadEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }
}
