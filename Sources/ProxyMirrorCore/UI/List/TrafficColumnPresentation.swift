import AppKit
import Foundation

/// 原生表格单元格的展示值与排序键分开，避免时间、大小等字段显示原始排序值。
@MainActor
enum TrafficColumnPresentation {
    static func text(_ column: TrafficColumn, transaction tx: Transaction) -> String {
        switch column {
        case .sequence: return String(tx.seq)
        case .url: return (tx.originalURL ?? tx.fullURL) + (tx.isGRPCWeb ? " · gRPC-Web" : "")
        case .client: return tx.clientName ?? Strings.Traffic.unknown
        case .method: return tx.method
        case .status:
            if tx.state == .failed { return tx.statusCode > 0 ? Strings.Traffic.failed(tx.statusCode) : Strings.Traffic.failed2 }
            return tx.statusCode == 0 ? Strings.Traffic.inProgress : String(tx.statusCode)
        case .time: return tx.timeText
        case .duration: return tx.state == .pending || tx.state == .awaiting ? "–" : tx.durationText
        case .request: return size(max(tx.requestBytes, tx.requestBody.count))
        case .response: return size(max(tx.responseBytes, tx.responseBody.count))
        case .ssl, .edited: return ""
        case .comment: return tx.comment
        case .tools: return tx.ruleMatches.joined(separator: ", ")
        case .graphql: return CustomColumnValues.shared.graphqlValue(for: tx)
        case .scheme: return tx.scheme.uppercased()
        case .contentType: return tx.responseHeaders.value(of: "Content-Type") ?? "–"
        case .custom(let field):
            let value = field.value(for: tx)
            return value.isEmpty ? "–" : value
        }
    }

    static func tooltip(_ column: TrafficColumn, transaction: Transaction) -> String {
        if column == .status { return transaction.localizedErrorText ?? transaction.statusText }
        if column == .ssl, transaction.isTLSIntercepted { return Strings.Traffic.decrypted }
        if column == .edited, transaction.originalURL != nil { return Strings.Traffic.edited }
        if column == .url, transaction.suspectedPinning {
            return (transaction.originalURL ?? transaction.fullURL) + "\n" + Strings.Traffic.theClientRejectedTheProxyCertificate
        }
        return text(column, transaction: transaction)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static func size(_ bytes: Int) -> String {
        bytes == 0 ? "–" : byteFormatter.string(fromByteCount: Int64(bytes))
    }
}
