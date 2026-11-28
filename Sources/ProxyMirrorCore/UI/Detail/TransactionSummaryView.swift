import AppKit
import Foundation
import SwiftUI

struct TransactionSummaryView: View {
    @ObservedObject var tx: Transaction
    var showConnection: () -> Void
    @State private var showingCertificate = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SummaryKeyValueGrid(title: Strings.Summary.general, rows: [
                    (Strings.Detail.url, tx.originalURL ?? tx.fullURL),
                    (Strings.Detail.method, tx.method),
                    (Strings.Detail.status, tx.statusCode > 0 ? tx.statusText : "—"),
                    (Strings.Detail.clientProtocol, tx.requestVersion),
                    (Strings.Detail.upstreamProtocol, tx.upstreamProtocol ?? (tx.statusCode > 0 ? tx.responseVersion : "—")),
                    (Strings.Detail.client, tx.clientName ?? "—"),
                    (Strings.Summary.bundleId, tx.clientBundle ?? "—"),
                    (Strings.Detail.clientAddress, tx.clientAddress ?? "—"),
                    (Strings.Detail.upstreamAddress, tx.connectionDetails?.address ?? "—"),
                    (Strings.Detail.dnsMappingAddress, tx.resolvedAddress ?? "—"),
                    (Strings.Summary.startedAt, PresentationTime.string(from: tx.startedAt)),
                    (Strings.Detail.duration, tx.durationText),
                    (Strings.Summary.requestSize, PresentationNumbers.byteCount(Int64(max(tx.requestBytes, tx.requestBody.count)))),
                    (Strings.Summary.responseSize, PresentationNumbers.byteCount(Int64(max(tx.responseBytes, tx.responseBody.count)))),
                    (Strings.Summary.contentType, tx.contentType.isEmpty ? "—" : tx.contentType),
                ])
                if tx.scheme == "https" || tx.connectionDetails?.tlsVersion != nil || tx.connectionDetails?.clientTLSVersion != nil {
                    SummaryKeyValueGrid(title: "TLS", rows: [
                        (Strings.Summary.upstreamTls, tx.connectionDetails?.tlsVersion ?? "—"),
                        (Strings.Detail.upstreamAlpn, tx.connectionDetails?.alpn ?? "—"),
                        (Strings.Summary.clientTls, tx.connectionDetails?.clientTLSVersion ?? "—"),
                        (Strings.Summary.cipherSuite, "—"),
                    ])
                }
                if let certificate = tx.connectionDetails?.serverCertificate {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(Strings.Summary.serverCertificate)
                                .font(PresentationFonts.swiftUIFont(weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button { showingCertificate = true } label: {
                                Label(Strings.Summary.preview, systemImage: "eye")
                            }
                            .controlSize(.mini)
                        }
                        SummaryKeyValueGrid(rows: [
                            (Strings.Summary.subject, certificate.subject),
                            (Strings.Summary.issuer, certificate.issuer),
                            (Strings.Summary.validUntil, certificate.validUntil.formatted(date: .numeric, time: .standard)),
                        ])
                    }
                }
                Button(Strings.Summary.connectionTiming, action: showConnection)
                    .buttonStyle(.link)
            }
            .padding(12)
        }
        .sheet(isPresented: $showingCertificate) {
            if let certificate = tx.connectionDetails?.serverCertificate {
                TLSCertificateDetailSheet(certificate: certificate)
            }
        }
    }
}

private struct SummaryKeyValueGrid: View {
    var title: String? = nil
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(PresentationFonts.swiftUIFont(weight: .semibold)).foregroundStyle(.secondary)
            }
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    Text(rows[index].0).fontWeight(.medium)
                        .frame(width: 125, alignment: .leading)
                    Text(rows[index].1).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(rows[index].1, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .help(Strings.Common.copy).buttonStyle(.borderless)
                }
                .font(PresentationFonts.swiftUIFont())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TLSCertificateDetailSheet: View {
    let certificate: TLSCertificateDetails
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Strings.Summary.serverCertificate).font(.title2)
            Text(Strings.Summary.leafCertificateOnly).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                SummaryKeyValueGrid(rows: [
                    (Strings.Summary.subject, certificate.subject),
                    (Strings.Summary.issuer, certificate.issuer),
                    (Strings.Summary.validFrom, certificate.validFrom.formatted(date: .numeric, time: .standard)),
                    (Strings.Summary.validUntil, certificate.validUntil.formatted(date: .numeric, time: .standard)),
                    (Strings.Summary.alternativeNames, certificate.subjectAlternativeNames.joined(separator: "\n")),
                    (Strings.Summary.publicKey, certificate.publicKey),
                    (Strings.Summary.signatureAlgorithm, certificate.signatureAlgorithm),
                    (Strings.Summary.sha256, certificate.fingerprintSHA256),
                ])
                .padding(.trailing, 6)
            }
            HStack {
                Spacer()
                Button(Strings.Common.close) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 470)
    }
}
