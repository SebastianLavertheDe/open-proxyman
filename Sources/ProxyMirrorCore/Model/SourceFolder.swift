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

enum SourceFolderError: LocalizedError, OperationIssueProviding {
    case blankName, duplicateName, missing, invalidFile

    var operationIssue: OperationIssue {
        switch self {
        case .blankName: return OperationIssue.modelSourceFolderNameRequired
        case .duplicateName: return OperationIssue.modelSourceFolderDuplicate
        case .missing: return OperationIssue.modelSourceFolderMissing
        case .invalidFile: return OperationIssue.modelSourceFolderInvalid
        }
    }
    var errorDescription: String? { operationIssue.diagnostic }
}

struct SourceFolderArchive: Codable {
    static let currentVersion = 2
    private var version = Self.currentVersion
    private var folders: [SourceFolder]

    static var defaultURL: URL {
        CertificateAuthority.applicationSupport.appendingPathComponent("SourceFolders.json")
    }

    static func read(_ url: URL) throws -> [SourceFolder] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let archive = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url)),
              archive.version == Self.currentVersion, Set(archive.folders.map(\.id)).count == archive.folders.count else {
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
