import Foundation
import X509

/// Shared by every capture-root import path, before any persistent state changes.
enum RootCAValidation {
    enum Failure: Error, Equatable {
        case outsideValidity, keyMismatch, notCertificateAuthority, signingNotPermitted
    }

    static func validate(_ certificate: Certificate, privateKey: Certificate.PrivateKey,
                         now: Date = Date()) throws {
        guard certificate.notValidBefore <= now, now < certificate.notValidAfter else {
            throw Failure.outsideValidity
        }
        guard privateKey.publicKey == certificate.publicKey else { throw Failure.keyMismatch }
        guard case .isCertificateAuthority? = try certificate.extensions.basicConstraints else {
            throw Failure.notCertificateAuthority
        }
        if let usage = try certificate.extensions.keyUsage, !usage.keyCertSign {
            throw Failure.signingNotPermitted
        }
    }
}
