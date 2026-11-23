import Foundation

/// Reads protoc FileDescriptorSet metadata. Decoding preserves captured field order and unknown fields.
struct GRPCSchema: Sendable {
    static let maxDescriptorBytes = 4 * 1024 * 1024

    fileprivate struct Field: Sendable {
        let name: String
        let type: FieldType
        let typeName: String?
        let repeated: Bool
    }

    private struct RPC: Sendable {
        let input: String
        let output: String
    }

    fileprivate var messages: [String: [Int: Field]] = [:]
    fileprivate var enums: [String: [Int32: String]] = [:]
    private var methods: [String: RPC] = [:]

    static func load(_ url: URL) throws -> GRPCSchema {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw GRPCInspectionError(Strings.Detail.chooseARegularDescriptorFile) }
        if let size = values.fileSize, size > maxDescriptorBytes {
            throw GRPCInspectionError(Strings.Detail.theDescriptorFileExceeds4Mib)
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var bytes = Data()
        while let next = try file.read(upToCount: 64 * 1024), !next.isEmpty {
            guard bytes.count + next.count <= maxDescriptorBytes else {
                throw GRPCInspectionError(Strings.Detail.theDescriptorFileExceeds4Mib)
            }
            bytes.append(next)
        }
        return try parse(bytes)
    }

    static func parse(_ data: Data) throws -> GRPCSchema {
        guard data.count <= maxDescriptorBytes else { throw GRPCInspectionError(Strings.Detail.theDescriptorFileExceeds4Mib) }
        let files = try ProtoWire.fields(data).messages(1)
        var schema = GRPCSchema()
        for file in files {
            let fields = try ProtoWire.fields(file)
            let package = fields.text(2) ?? ""
            for bytes in fields.messages(4) {
                try schema.addMessage(bytes, scope: package, depth: 0)
            }
            for bytes in fields.messages(5) {
                try schema.addEnum(bytes, scope: package)
            }
            for bytes in fields.messages(6) {
                let service = try ProtoWire.fields(bytes)
                guard let name = service.text(1), !name.isEmpty else { continue }
                let qualified = Self.qualified(name, in: package)
                for item in service.messages(2) {
                    let method = try ProtoWire.fields(item)
                    guard let name = method.text(1), let input = method.text(2), let output = method.text(3) else { continue }
                    schema.methods["/\(qualified)/\(name)"] = RPC(input: Self.normalized(input),
                                                                  output: Self.normalized(output))
                }
            }
        }
        guard !schema.messages.isEmpty else { throw GRPCInspectionError(Strings.Detail.theDescriptorContainsNoUsableMessageTypes) }
        return schema
    }

    func messageType(for path: String, isRequest: Bool) -> String? {
        guard let method = methods[path] else { return nil }
        return isRequest ? method.input : method.output
    }

    var messageTypes: [String] { messages.keys.sorted() }

    func contains(_ type: String) -> Bool { messages[Self.normalized(type)] != nil }

    fileprivate static let googleStatusType = "google.rpc.Status"
    fileprivate static let anyType = "google.protobuf.Any"

    fileprivate static let commonGoogleErrors: Self = {
        func field(_ name: String, _ type: FieldType, _ typeName: String? = nil, repeated: Bool = false) -> Field {
            Field(name: name, type: type, typeName: typeName, repeated: repeated)
        }
        var schema = Self()
        schema.messages = [
            googleStatusType: [1: field("code", .int32), 2: field("message", .string),
                               3: field("details", .message, anyType, repeated: true)],
            anyType: [1: field("type_url", .string), 2: field("value", .bytes)],
            "google.rpc.ErrorInfo": [1: field("reason", .string), 2: field("domain", .string),
                                     3: field("metadata", .message, "google.rpc.ErrorInfo.MetadataEntry", repeated: true)],
            "google.rpc.ErrorInfo.MetadataEntry": [1: field("key", .string), 2: field("value", .string)],
            "google.rpc.LocalizedMessage": [1: field("locale", .string), 2: field("message", .string)],
        ]
        return schema
    }()

    static func normalized(_ name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.hasPrefix(".") ? String(name.dropFirst()) : name
    }

    private static func qualified(_ name: String, in scope: String) -> String {
        scope.isEmpty ? name : scope + "." + name
    }

    private mutating func addMessage(_ bytes: Data, scope: String, depth: Int) throws {
        guard depth < 32, messages.count < 8192 else {
            throw GRPCInspectionError(Strings.Detail.theDescriptorContainsTooManyTypesOrNestingLevels)
        }
        let descriptor = try ProtoWire.fields(bytes)
        guard let name = descriptor.text(1), !name.isEmpty else {
            throw GRPCInspectionError(Strings.Detail.theDescriptorContainsAnUnnamedMessage)
        }
        let qualified = Self.qualified(name, in: scope)
        guard messages[qualified] == nil else { throw GRPCInspectionError(Strings.Detail.duplicateMessageType(String(describing: qualified))) }
        var declared: [Int: Field] = [:]
        for bytes in descriptor.messages(2) {
            let properties = try ProtoWire.fields(bytes)
            guard let name = properties.text(1), let rawNumber = properties.integer(3),
                  rawNumber > 0, rawNumber <= 536_870_911,
                  let rawType = properties.integer(5), let type = FieldType(rawValue: rawType) else { continue }
            let typeName = properties.text(6).map { Self.normalized($0) }
            declared[Int(rawNumber)] = Field(name: name, type: type, typeName: typeName,
                                             repeated: properties.integer(4) == 3)
        }
        messages[qualified] = declared
        for bytes in descriptor.messages(3) { try addMessage(bytes, scope: qualified, depth: depth + 1) }
        for bytes in descriptor.messages(4) { try addEnum(bytes, scope: qualified) }
    }

    private mutating func addEnum(_ bytes: Data, scope: String) throws {
        guard enums.count < 8192 else { throw GRPCInspectionError(Strings.Detail.theDescriptorContainsTooManyEnumTypes) }
        let descriptor = try ProtoWire.fields(bytes)
        guard let name = descriptor.text(1), !name.isEmpty else { return }
        var values: [Int32: String] = [:]
        for bytes in descriptor.messages(2) {
            let entry = try ProtoWire.fields(bytes)
            guard let name = entry.text(1), let number = entry.integer(2) else { continue }
            let key = Int32(truncatingIfNeeded: number)
            if values[key] == nil { values[key] = name }
        }
        enums[Self.qualified(name, in: scope)] = values
    }
}

enum GRPCProtobuf {
    static func describe(_ data: Data, type: String? = nil, schema: GRPCSchema? = nil) throws -> String {
        guard data.count <= GRPCFrames.maxPayload else { throw GRPCInspectionError(Strings.Detail.theMessageExceedsThe1MibDecodingLimit) }
        var renderer = Renderer(schema: schema)
        try renderer.render(data, type: type.map { GRPCSchema.normalized($0) }, depth: 0)
        return renderer.lines.joined(separator: "\n")
    }

    struct HTTPDescription: Sendable {
        let text: String
        let type: String?
    }

    static func describeHTTP(_ data: Data, isError: Bool) throws -> HTTPDescription {
        guard data.count <= GRPCFrames.maxPayload else { throw GRPCInspectionError(Strings.Detail.theProtobufBodyExceedsThe1MibDecodingLimit) }
        let isStatus = isError && looksLikeGoogleStatus(data)
        let type = isStatus ? GRPCSchema.googleStatusType : nil
        var renderer = Renderer(schema: isStatus ? .commonGoogleErrors : nil, showUnknownText: true)
        try renderer.render(data, type: type, depth: 0)
        return HTTPDescription(text: renderer.lines.joined(separator: "\n"), type: type)
    }

    private static func looksLikeGoogleStatus(_ data: Data) -> Bool {
        guard let fields = try? ProtoWire.fields(data),
              let code = fields.integer(1), (1...16).contains(code),
              fields.text(2) != nil else { return false }
        return fields.messages(3).contains { bytes in
            guard let any = try? ProtoWire.fields(bytes), let url = any.text(1) else { return false }
            return url.hasPrefix("type.googleapis.com/google.rpc.")
        }
    }

    private struct Renderer {
        let schema: GRPCSchema?
        let showUnknownText: Bool
        var lines: [String] = []
        private var remaining = 1500
        private var exhausted = false

        init(schema: GRPCSchema?, showUnknownText: Bool = false) {
            self.schema = schema
            self.showUnknownText = showUnknownText
        }

        mutating func render(_ data: Data, type: String?, depth: Int) throws {
            let fields = type.flatMap { schema?.messages[$0] } ?? [:]
            let anyPayloadType = type == GRPCSchema.anyType ? unpackedType(in: data) : nil
            var reader = ProtoWire(data)
            let indent = String(repeating: "  ", count: depth)
            while !reader.finished, !exhausted {
                try Task.checkCancellation()
                if remaining == 0 {
                    lines.append(indent + Strings.Detail.fieldPreviewLimit)
                    exhausted = true
                    return
                }
                remaining -= 1
                let record = try reader.field()
                let field = fields[record.number]
                let label = field.map { "\(Self.preview($0.name)) [\(record.number)]" } ?? "#\(record.number)"
                let prefix = indent + label + ": "
                let nestedType = record.number == 2 && anyPayloadType != nil ? anyPayloadType
                    : field?.type == .message ? field?.typeName : nil
                if case .bytes(let bytes) = record.value,
                   field?.type == .message || nestedType != nil ||
                    (field == nil && showUnknownText && Self.unknownText(bytes) == nil &&
                     !bytes.isEmpty && (try? ProtoWire.fields(bytes))?.isEmpty == false) {
                    if depth >= 16 {
                        lines.append(prefix + Self.byteSummary(bytes) + Strings.Detail.nestingLimit)
                    } else {
                        lines.append(prefix + "{")
                        try render(bytes, type: nestedType, depth: depth + 1)
                        lines.append(indent + "}")
                    }
                    continue
                }
                switch (field, record.value) {
                case (.some(let declaration), .bytes(let bytes)) where declaration.repeated && declaration.type.packable:
                    var packed = ProtoWire(bytes)
                    var values: [String] = []
                    while !packed.finished, values.count < 128, remaining > 0 {
                        values.append(scalar(try packed.value(wire: declaration.type.wire), field: declaration))
                        remaining -= 1
                    }
                    if !packed.finished { values.append("…") }
                    lines.append(prefix + "[" + values.joined(separator: ", ") + "]")
                default:
                    let validWire = field.map { $0.type.wire == record.value.wire } ?? true
                    let suffix = validWire ? "" : Strings.Detail.wireTypeDoesNotMatchDescriptor
                    lines.append(prefix + scalar(record.value, field: validWire ? field : nil) + suffix)
                }
            }
        }

        private func unpackedType(in data: Data) -> String? {
            guard let fields = try? ProtoWire.fields(data), let typeURL = fields.text(1),
                  let name = typeURL.split(separator: "/").last else { return nil }
            let type = String(name)
            return schema?.contains(type) == true ? type : nil
        }

        private func scalar(_ value: WireValue, field: GRPCSchema.Field?) -> String {
            switch value {
            case .varint(let number):
                switch field?.type {
                case .int32: return String(Int32(truncatingIfNeeded: number))
                case .int64: return String(Int64(bitPattern: number))
                case .uint32: return String(UInt32(truncatingIfNeeded: number))
                case .sint32: return String(Int32(truncatingIfNeeded: Self.zigzag(number)))
                case .sint64: return String(Self.zigzag(number))
                case .bool: return number == 0 ? "false" : "true"
                case .enumeration:
                    let signed = Int32(truncatingIfNeeded: number)
                    let name = field?.typeName.flatMap { schema?.enums[$0]?[signed] }
                    return name.map { "\(Self.preview($0)) (\(signed))" } ?? String(signed)
                default: return String(number)
                }
            case .fixed64(let number):
                switch field?.type {
                case .double: return String(Double(bitPattern: number))
                case .sfixed64: return String(Int64(bitPattern: number))
                default: return String(number)
                }
            case .fixed32(let number):
                switch field?.type {
                case .float: return String(Float(bitPattern: number))
                case .sfixed32: return String(Int32(bitPattern: number))
                default: return String(number)
                }
            case .bytes(let bytes):
                if field?.type == .string, let text = String(data: bytes, encoding: .utf8) {
                    return Self.stringPreview(text)
                }
                if field == nil, showUnknownText, let text = Self.unknownText(bytes) {
                    return Self.stringPreview(text)
                }
                return Self.byteSummary(bytes)
            }
        }

        private static func unknownText(_ bytes: Data) -> String? {
            guard bytes.count <= 4096, let text = String(data: bytes, encoding: .utf8), !text.isEmpty,
                  text.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" || $0 == "\t"
                  }) else { return nil }
            return text
        }

        private static func stringPreview(_ text: String) -> String {
            let prefix = String(text.unicodeScalars.prefix(256))
            return String(reflecting: prefix) + (prefix == text ? "" : "…")
        }

        private static func zigzag(_ number: UInt64) -> Int64 {
            Int64(bitPattern: number >> 1) ^ -Int64(number & 1)
        }

        private static func preview(_ text: String) -> String {
            let prefix = String(text.unicodeScalars.prefix(128))
            return prefix == text ? prefix : prefix + "…"
        }

        private static func byteSummary(_ data: Data) -> String {
            let hex = data.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
            return Strings.Detail.bytes2(data.count) + (hex.isEmpty ? "" : " · " + hex + (data.count > 24 ? " …" : ""))
        }
    }
}

private enum FieldType: UInt64, Sendable {
    case double = 1, float, int64, uint64, int32, fixed64, fixed32, bool, string, group
    case message, bytes, uint32, enumeration, sfixed32, sfixed64, sint32, sint64

    var packable: Bool { wire != 2 && wire != 3 }

    var wire: UInt64 {
        switch self {
        case .double, .fixed64, .sfixed64: return 1
        case .string, .message, .bytes: return 2
        case .group: return 3
        case .float, .fixed32, .sfixed32: return 5
        default: return 0
        }
    }
}

private enum WireValue {
    case varint(UInt64), fixed64(UInt64), bytes(Data), fixed32(UInt32)

    var wire: UInt64 {
        switch self {
        case .varint: return 0
        case .fixed64: return 1
        case .bytes: return 2
        case .fixed32: return 5
        }
    }
}

private struct WireField {
    let number: Int
    let value: WireValue
}

private extension Array where Element == WireField {
    func text(_ number: Int) -> String? {
        guard case .bytes(let data)? = first(where: { $0.number == number })?.value else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func integer(_ number: Int) -> UInt64? {
        guard case .varint(let value)? = first(where: { $0.number == number })?.value else { return nil }
        return value
    }

    func messages(_ number: Int) -> [Data] {
        compactMap {
            guard $0.number == number, case .bytes(let value) = $0.value else { return nil }
            return value
        }
    }
}

private struct ProtoWire {
    let data: Data
    private var cursor: Int

    init(_ data: Data) { self.data = data; cursor = data.startIndex }

    var finished: Bool { cursor == data.endIndex }

    static func fields(_ data: Data) throws -> [WireField] {
        var reader = Self(data)
        var result: [WireField] = []
        while !reader.finished {
            guard result.count < 32_768 else { throw GRPCInspectionError(Strings.Detail.theDescriptorContainsTooManyFields) }
            if result.count.isMultiple(of: 128) { try Task.checkCancellation() }
            result.append(try reader.field())
        }
        return result
    }

    mutating func field() throws -> WireField {
        let key = try varint()
        let number = key >> 3
        guard number > 0, number <= 536_870_911 else { throw invalid(Strings.Detail.invalidFieldNumber) }
        return WireField(number: Int(number), value: try value(wire: key & 7))
    }

    mutating func value(wire: UInt64) throws -> WireValue {
        switch wire {
        case 0: return .varint(try varint())
        case 1: return .fixed64(try fixed(8))
        case 2:
            let length = try varint()
            guard length <= UInt64(data.endIndex - cursor) else { throw invalid(Strings.Detail.fieldLengthExceedsTheRemainingData) }
            let end = cursor + Int(length)
            let bytes = data[cursor..<end]
            cursor = end
            return .bytes(bytes)
        case 5: return .fixed32(UInt32(try fixed(4)))
        default: throw invalid(Strings.Detail.unsupportedWireType(Int(wire)))
        }
    }

    private mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<10 {
            guard !finished else { throw invalid(Strings.Detail.truncatedVarint) }
            let byte = data[cursor]
            cursor += 1
            guard index < 9 || byte <= 1 else { throw invalid(Strings.Detail.varintOverflow) }
            result |= UInt64(byte & 127) << (index * 7)
            if byte & 128 == 0 { return result }
        }
        throw invalid(Strings.Detail.varintOverflow)
    }

    private mutating func fixed(_ count: Int) throws -> UInt64 {
        guard count <= data.endIndex - cursor else { throw invalid(Strings.Detail.truncatedFixedWidthField) }
        var value: UInt64 = 0
        for index in 0..<count {
            value |= UInt64(data[cursor + index]) << (index * 8)
        }
        cursor += count
        return value
    }

    private func invalid(_ issue: String) -> GRPCInspectionError {
        GRPCInspectionError(Strings.Detail.protobufOffset(cursor - data.startIndex, issue))
    }
}
