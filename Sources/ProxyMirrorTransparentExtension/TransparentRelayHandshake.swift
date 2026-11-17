import CryptoKit
import Foundation

struct TransparentRelayHandshake {
    private struct Destination: Encodable {
        let host: String
        let address: String?
        let port: Int
        let application: String?
    }

    private static let hexadecimal = Array("0123456789abcdef".utf8)
    static let responseLength = 69 // OK, a space, 64 hexadecimal digits, and CRLF.

    let request: Data
    private let key: SymmetricKey
    private let challenge: String

    init?(token: String, host: String, address: String?, port: Int, application: String?) {
        let key = SymmetricKey(data: Data(token.utf8))
        let challenge = UUID().uuidString.lowercased()
        let destination = Destination(host: host, address: address, port: port, application: application)
        guard let destinationJSON = try? JSONEncoder().encode(destination) else { return nil }

        var request = Data("PMTP/1 \(challenge)\r\n".utf8)
        request.append(destinationJSON)
        request.append(contentsOf: [13, 10])
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: request, using: key)
        for byte in authenticationCode {
            request.append(Self.hexadecimal[Int(byte >> 4)])
            request.append(Self.hexadecimal[Int(byte & 15)])
        }
        request.append(contentsOf: [13, 10])
        guard request.count <= 4096 else { return nil }

        self.request = request
        self.key = key
        self.challenge = challenge
    }

    func accepts(_ response: Data) -> Bool {
        let bytes = Array(response)
        guard bytes.count == Self.responseLength,
              bytes.starts(with: "OK ".utf8), bytes.suffix(2).elementsEqual([13, 10]) else {
            return false
        }

        var authenticationCode = Data()
        authenticationCode.reserveCapacity(32)
        for index in stride(from: 3, to: 67, by: 2) {
            guard let high = Self.hexadecimal.firstIndex(of: bytes[index]),
                  let low = Self.hexadecimal.firstIndex(of: bytes[index + 1]) else { return false }
            authenticationCode.append(UInt8(high << 4 | low))
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            authenticationCode,
            authenticating: Data("PMTP/1 OK \(challenge)\r\n".utf8),
            using: key
        )
    }
}
