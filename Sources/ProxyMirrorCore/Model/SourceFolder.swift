import Foundation

enum SourceFolderMember: Hashable, Codable {
    case domain(String)
    case client(String)

    var name: String {
        switch self {
        case .domain(let host), .client(let host): return host
        }
    }

    var isDomain: Bool {
        if case .domain = self { return true }
        return false
    }

    var normalized: Self {
        switch self {
        case .domain(let host): return .domain(host.lowercased())
        case .client: return self
        }
    }

    static func captured(_ transaction: Transaction) -> [Self] {
        var values = [Self.domain(transaction.host.lowercased())]
        if let app = transaction.clientName, !app.isEmpty { values.append(.client(app)) }
        return values
    }
}

struct SourceFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var members: Set<SourceFolderMember> = []

    func matches(_ transaction: Transaction) -> Bool {
        SourceFolderMember.captured(transaction).contains { members.contains($0) }
    }
}

enum SourceFolderError: LocalizedError {
    case blankName, duplicateName, missing, invalidFile

    var errorDescription: String? {
        switch self {
        case .blankName: return "请输入文件夹名称。"
        case .duplicateName: return "已有同名来源文件夹。"
        case .missing: return "该来源文件夹已被删除。"
        case .invalidFile: return "无法读取现有来源文件夹配置。"
        }
    }
}

struct SourceFolderArchive: Codable {
    private var version = 1
    private var folders: [SourceFolder]

    static var defaultURL: URL {
        CertificateAuthority.applicationSupport.appendingPathComponent("SourceFolders.json")
    }

    static func read(_ url: URL) throws -> [SourceFolder] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let archive = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url)),
              archive.version == 1, Set(archive.folders.map(\.id)).count == archive.folders.count else {
            throw SourceFolderError.invalidFile
        }
        return archive.folders.map { folder in
            var normalized = folder
            normalized.members = Set(folder.members.map(\.normalized))
            return normalized
        }
    }

    static func write(_ folders: [SourceFolder], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Self(folders: folders)).write(to: url, options: .atomic)
    }
}
