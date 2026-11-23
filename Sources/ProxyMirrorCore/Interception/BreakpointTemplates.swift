import Foundation
import NIOHTTP1

struct BreakpointTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var phase: BreakpointRule.Phase
    /// A missing body preserves the original; framing and connection headers are always preserved.
    var headers: HTTPHeaders
    var body: Data?
    var status: Int?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.phase == rhs.phase
            && lhs.headers.rawBytes == rhs.headers.rawBytes && lhs.body == rhs.body && lhs.status == rhs.status
    }

    static func capture(name: String, phase: BreakpointRule.Phase, message: BreakpointMessage) -> Self {
        var status: Int?
        if case .response(let head) = message.head { status = head.status }
        return Self(name: name, phase: phase, headers: message.head.headers, body: message.body, status: status)
    }

    func draft(for message: BreakpointMessage, phase: BreakpointRule.Phase) throws -> String {
        guard self.phase == phase else { throw BreakpointMessage.InvalidEdit("模板阶段与当前断点不匹配") }
        var head = message.head
        if case .response(var response) = head, let status,
           BreakpointMessage.noBodyStatus(status) == BreakpointMessage.noBodyStatus(response.status) {
            response.status = status
            response.reason = NIOHTTP1.HTTPResponseStatus(statusCode: status).reasonPhrase
            head = .response(response)
        }
        var merged = headers
        for field in ["Host", "Connection", "Proxy-Connection", "Upgrade", "Expect", "Transfer-Encoding", "Trailer", "Content-Encoding", "Content-Length"] {
            merged.remove(name: field)
            for value in message.head.headers.values(of: field) { merged.append(field, value) }
        }
        let replacement = message.body == nil ? nil : (body ?? message.body)
        let draft = BreakpointMessage(head: head.replacingHeaders(merged), body: replacement).text
        _ = try message.applying(draft)
        return draft
    }
}

@MainActor
final class BreakpointTemplateStore: ObservableObject {
    static let shared = BreakpointTemplateStore()
    @Published private(set) var templates: [BreakpointTemplate] = []
    private let url: URL
    init(directory: URL = CertificateAuthority.applicationSupport) {
        url = directory.appendingPathComponent("breakpoint-templates.json")
        if let bytes = try? Data(contentsOf: url), bytes.count <= 8 * 1024 * 1024,
           let decoded = try? JSONDecoder().decode([BreakpointTemplate].self, from: bytes) { templates = decoded }
    }
    func save(_ template: BreakpointTemplate) throws {
        var next = templates.filter { $0.id != template.id }
        guard next.count < 100 else { throw BreakpointMessage.InvalidEdit("最多保存 100 个断点模板") }
        next.append(template)
        try persist(next)
    }
    func remove(_ id: UUID) throws { try persist(templates.filter { $0.id != id }) }
    private func persist(_ next: [BreakpointTemplate]) throws {
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count <= 8 * 1024 * 1024 else { throw BreakpointMessage.InvalidEdit("模板库超过 8 MiB") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateAppFile.write(bytes, to: url)
        templates = next
    }
}
