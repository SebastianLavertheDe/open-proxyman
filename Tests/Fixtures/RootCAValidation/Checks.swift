import Foundation
import Crypto
import X509

@main
struct RootCAValidationChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let otherKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let subject = try DistinguishedName { CommonName("Root validation fixture") }
        var count = 0
        func certificate(before: Date = now.addingTimeInterval(-100), after: Date = now.addingTimeInterval(100),
                         ca: Bool = true, signing: Bool? = true) throws -> Certificate {
            try Certificate(version: .v3, serialNumber: .init(bytes: [1]), publicKey: key.publicKey,
                notValidBefore: before, notValidAfter: after, issuer: subject, subject: subject,
                extensions: try Certificate.Extensions {
                    Critical(ca ? BasicConstraints.isCertificateAuthority(maxPathLength: nil) : .notCertificateAuthority)
                    if let signing { Critical(KeyUsage(digitalSignature: true, keyCertSign: signing)) }
                }, issuerPrivateKey: key)
        }
        func reject(_ certificate: Certificate, _ expected: RootCAValidation.Failure,
                    privateKey: Certificate.PrivateKey? = nil) throws {
            do {
                try RootCAValidation.validate(certificate, privateKey: privateKey ?? key, now: now)
                preconditionFailure("Expected \(expected)")
            } catch let failure as RootCAValidation.Failure {
                precondition(failure == expected, "Expected \(expected), received \(failure)")
                count += 1
            }
        }
        try RootCAValidation.validate(certificate(), privateKey: key, now: now); count += 1
        try RootCAValidation.validate(certificate(signing: nil), privateKey: key, now: now); count += 1
        try RootCAValidation.validate(certificate(before: now), privateKey: key, now: now); count += 1
        try reject(certificate(after: now), .outsideValidity)
        try reject(certificate(after: now.addingTimeInterval(-1)), .outsideValidity)
        try reject(certificate(before: now.addingTimeInterval(1)), .outsideValidity)
        try reject(certificate(), .keyMismatch, privateKey: otherKey)
        try reject(certificate(ca: false), .notCertificateAuthority)
        try reject(certificate(signing: false), .signingNotPermitted)
        print("PASS: \(count) native production root-CA validation checks (validity boundaries, CA constraints, key match and keyCertSign)")
    }
}
