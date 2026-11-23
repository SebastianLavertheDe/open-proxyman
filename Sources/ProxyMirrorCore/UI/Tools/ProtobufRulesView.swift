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
                Toggle(Strings.Tools.enableMapping, isOn: Binding(get: { store.configuration.enabled }, set: { enabled in
                    var next = store.configuration; next.enabled = enabled
                    save(next)
                }))
            }
            TabView(selection: $selectedTab) {
                schemas.tabItem { Text("Schema") }.tag(0)
                mappings.tabItem { Text(Strings.Tools.messageMappings) }.tag(1)
                converter.tabItem { Text(Strings.Tools.converter) }.tag(2)
                console.tabItem { Text(Strings.Tools.console) }.tag(3)
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
                Button(Strings.Tools.importDescPb) { importing = true }.disabled(store.loading)
                if store.loading { ProgressView().controlSize(.small) }
                Spacer()
                Text(Strings.Tools.schemas(Int(store.configuration.schemas.count))).foregroundStyle(.secondary)
            }
            Text(Strings.Tools.generateDescriptorsWithProtocDescriptorSetOutServiceDesc)
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
                        Text(Strings.Tools.types(Int(store.schemaNames(id: record.id).count))).font(.caption).foregroundStyle(.secondary)
                        Button(Strings.Tools.remove) { do { try store.removeSchema(record.id) } catch { store.fail(error) } }
                    }
                    DisclosureGroup(Strings.Tools.messageTypes) {
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
                Button(Strings.Tools.addMapping) {
                    var rule = ProtobufMappingRule(); rule.schemaID = store.configuration.schemas.first?.id; editing = rule
                }
                Spacer()
                Text(Strings.Tools.useTheFirstMatchingRuleInOrder).font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(store.configuration.rules) { rule in
                    HStack {
                        Toggle(Strings.Tools.enableRule, isOn: Binding(get: { rule.enabled }, set: { enabled in
                            var next = store.configuration
                            if let index = next.rules.firstIndex(where: { $0.id == rule.id }) { next.rules[index].enabled = enabled }
                            save(next)
                        })).labelsHidden()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.name)
                            Text(rule.pattern).font(.caption).foregroundStyle(.secondary)
                            Text(Strings.Tools.protobufMappingSummary(String(describing: rule.requestMessage.isEmpty ? Strings.Tools.fieldNumbers : rule.requestMessage), String(describing: rule.requestEncoding.localizedTitle), String(describing: rule.responseMessage.isEmpty ? Strings.Tools.fieldNumbers : rule.responseMessage), String(describing: rule.responseEncoding.localizedTitle)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(Strings.Tools.edit) { editing = rule }
                        Button(Strings.Tools.delete) {
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
                    Text(Strings.Tools.noSchema).tag(nil as UUID?)
                    ForEach(store.configuration.schemas) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField(Strings.Tools.fullyQualifiedMessageTypeOptional, text: $converterMessage)
            }
            HStack {
                Toggle(Strings.Tools.inputIsBase64, isOn: $converterBase64)
                Picker(Strings.Tools.encode, selection: $converterEncoding) {
                    ForEach(ProtobufPayloadEncoding.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                }.frame(width: 210)
                Spacer()
                Button(Strings.Tools.decode) { convert() }.disabled(converterBusy || converterInput.isEmpty)
                if converterBusy { ProgressView().controlSize(.small) }
            }
            Text(Strings.Tools.whenBase64IsDisabledEnterHexadecimalBytesDelimitedMode)
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
                Toggle(Strings.Tools.errorsOnly, isOn: $errorsOnly)
                Spacer()
                Button(Strings.Tools.clear) { store.clearConsole() }
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
                    guard input.utf8.count <= GRPCFrames.maxPayload * 4 else { throw GRPCInspectionError(Strings.Tools.theConversionInputIsTooLarge) }
                    let bytes: Data
                    if base64 {
                        guard let decoded = Data(base64Encoded: input.filter { !$0.isWhitespace }) else { throw GRPCInspectionError(Strings.Tools.theBase64InputIsInvalid) }
                        bytes = decoded
                    } else {
                        let compact = input.filter { !$0.isWhitespace }
                        guard compact.count % 2 == 0, compact.allSatisfy({ $0.isHexDigit }) else { throw GRPCInspectionError(Strings.Tools.theHexadecimalInputIsInvalid) }
                        let chars = Array(compact)
                        var decoded = Data()
                        for index in stride(from: 0, to: chars.count, by: 2) {
                            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { throw GRPCInspectionError(Strings.Tools.theHexadecimalInputIsInvalid) }
                            decoded.append(byte)
                        }
                        bytes = decoded
                    }
                    if !type.isEmpty, schema?.contains(type) != true { throw GRPCInspectionError(Strings.Tools.chooseASchemaContainingThisMessageType) }
                    let messages = try ProtobufPayload.messages(bytes, encoding: encoding)
                    return try ProtobufPayload.describeMessages(messages, type: type.isEmpty ? nil : type, schema: schema)
                }.value
                converterOutput = result
                store.log(Strings.Tools.converterDecodedSuccessfully)
            } catch { converterOutput = LocalizedErrorPresentation.message(for: error); store.fail(error) }
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
            Text(Strings.Tools.protobufMessageMapping).font(.headline)
            TextField(Strings.Tools.name, text: $rule.name)
            TextField(Strings.Tools.fullUrlOrPathPattern, text: $rule.pattern)
            Picker("Schema", selection: $rule.schemaID) {
                Text(Strings.Tools.choose).tag(nil as UUID?)
                ForEach(store.configuration.schemas) { Text($0.name).tag(Optional($0.id)) }
            }
            Group {
                messageField(Strings.Tools.requestMessage, $rule.requestMessage)
                encodingPicker(Strings.Tools.requestEncoding, $rule.requestEncoding)
                messageField(Strings.Tools.responseMessage, $rule.responseMessage)
                encodingPicker(Strings.Tools.responseEncoding, $rule.responseEncoding)
            }
            Picker(Strings.Tools.bodyType, selection: $rule.payloadType) {
                ForEach(ProtobufPayloadType.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(Strings.Tools.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.Tools.save) { onSave(rule) }.keyboardShortcut(.defaultAction).disabled(rule.schemaID == nil || rule.name.isEmpty)
            }
        }.padding(20).frame(width: 560)
    }

    private func messageField(_ label: String, _ value: Binding<String>) -> some View {
        HStack {
            TextField(label, text: value)
            Menu(Strings.Tools.select) {
                Button(Strings.Tools.byFieldNumber) { value.wrappedValue = "" }
                ForEach(store.schemaNames(id: rule.schemaID), id: \.self) { type in Button(type) { value.wrappedValue = type } }
            }.fixedSize()
        }
    }

    private func encodingPicker(_ label: String, _ value: Binding<ProtobufPayloadEncoding>) -> some View {
        Picker(label, selection: value) {
            ForEach(ProtobufPayloadEncoding.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
        }
    }
}
