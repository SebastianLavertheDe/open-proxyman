import CryptoKit
import Foundation

@_spi(Transport) public enum BridgeWire {
    public static let serviceType = "_proxymirror._tcp"
    public static let bodyLimit = 1024 * 1024
    private static let headerLimit = 64 * 1024
    public static let frameLimit = 4 + headerLimit + 2 * bodyLimit + 28
    private static let context = Data("ProxyMirrorBridge/1".utf8)

    public struct Pairing: Sendable {
        public let name: String
        fileprivate let keyData: Data
        fileprivate var key: SymmetricKey { SymmetricKey(data: keyData) }

        public init() {
            name = "ProxyMirror-\(UUID().uuidString)"
            keyData = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        }

        public init(code: String) throws {
            let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
            guard parts.count == 2,
                  parts[0].hasPrefix("ProxyMirror-"),
                  UUID(uuidString: String(parts[0].dropFirst("ProxyMirror-".count))) != nil,
                  let keyData = Data(base64Encoded: String(parts[1])), keyData.count == 32 else {
                throw Failure.invalidPairingCode
            }
            name = String(parts[0])
            self.keyData = keyData
        }

        public var code: String {
            "\(name):\(keyData.base64EncodedString())"
        }
    }

    public struct Header: Codable, Sendable {
        public struct Field: Codable, Sendable {
            public let name: String
            public let value: String
        }

        var version = 1
        public var id = UUID()
        public let app: String
        public let device: String
        public let url: URL
        public let method: String
        public let startedAt: Date
        public let duration: TimeInterval
        public let status: Int?
        public let error: String?
        public let requestHeaders: [Field]
        public let responseHeaders: [Field]
        public let requestBytes: Int
        public let responseBytes: Int
        public let requestStreamed: Bool
        var requestLength: Int
        var responseLength: Int
    }

    public struct Capture: Sendable {
        public let header: Header
        public let request: Data
        public let response: Data
    }

    enum Failure: LocalizedError {
        case invalidPairingCode, invalidFrame

        var errorDescription: String? {
            switch self {
            case .invalidPairingCode: return "Invalid ProxyMirror pairing code."
            case .invalidFrame: return "Invalid ProxyMirror capture frame."
            }
        }
    }

    public static func encode(_ capture: Capture, pairing: Pairing) throws -> Data {
        let header = try JSONEncoder().encode(capture.header)
        guard header.count <= headerLimit else { throw Failure.invalidFrame }
        var payload = lengthPrefix(header.count)
        payload.append(header)
        payload.append(capture.request)
        payload.append(capture.response)
        let sealed = try AES.GCM.seal(payload, using: pairing.key, authenticating: context)
        guard let encrypted = sealed.combined, encrypted.count <= frameLimit else { throw Failure.invalidFrame }
        return lengthPrefix(encrypted.count) + encrypted
    }

    public static func decode(_ frame: Data, pairing: Pairing) throws -> Capture {
        guard (32...frameLimit).contains(frame.count) else { throw Failure.invalidFrame }
        let sealed = try AES.GCM.SealedBox(combined: frame)
        let payload = try AES.GCM.open(sealed, using: pairing.key, authenticating: context)
        let headerLength = length(payload.prefix(4))
        guard (1...headerLimit).contains(headerLength), payload.count >= 4 + headerLength else {
            throw Failure.invalidFrame
        }
        let offset = 4 + headerLength
        let header = try JSONDecoder().decode(Header.self, from: payload[4..<offset])
        guard header.version == 1, (0...bodyLimit).contains(header.requestLength),
              (0...bodyLimit).contains(header.responseLength),
              header.requestBytes >= header.requestLength, header.responseBytes >= header.responseLength,
              header.requestBytes <= Int(Int32.max), header.responseBytes <= Int(Int32.max),
              payload.count == offset + header.requestLength + header.responseLength,
              header.duration.isFinite, header.duration >= 0,
              header.startedAt.timeIntervalSinceReferenceDate.isFinite,
              header.status.map({ (100...599).contains($0) }) ?? (header.error != nil) else {
            throw Failure.invalidFrame
        }
        return Capture(header: header, request: payload.subdata(in: offset..<(offset + header.requestLength)),
                       response: Data(payload.suffix(header.responseLength)))
    }

    public static func length(_ prefix: Data) -> Int {
        prefix.reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func lengthPrefix(_ count: Int) -> Data {
        withUnsafeBytes(of: UInt32(count).bigEndian) { Data($0) }
    }
}
