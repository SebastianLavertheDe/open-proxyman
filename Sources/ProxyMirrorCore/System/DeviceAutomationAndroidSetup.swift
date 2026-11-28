import Foundation
import ProxyMirrorFoundation

extension DeviceAutomation {
    /// Legacy caller entry point shares the multi-device, recoverable certificate installer.
    static func setupAndroidEmulator(certificatePath: String,
                                      cancellation: DeviceCommandRunner.Cancellation? = nil) throws -> String {
        if cancellation?.isCancelled == true { throw DeviceCommandRunner.Failure.cancelled }
        guard try androidDevices(cancellation: cancellation).contains(where: { $0.hasPrefix("emulator-") }) else {
            throw AutomationError.unsupportedAndroidDevice
        }
        let installed = try withAndroidCertificateSnapshot(certificatePath) { snapshot in
            let hash = try androidCertificateHash(certificatePath: snapshot.path, cancellation: cancellation)
            let devices = try androidSetup.devices(certificateHash: hash)
            return try androidSetup.override(devices, certificate: snapshot,
                certificateHash: hash, proxy: "", setProxy: false)
        }
        guard !installed.isEmpty else { throw AutomationError.unsupportedAndroidDevice }
        return installed.joined(separator: "\n")
    }

    /// A durable journal lets the device guide recover an interrupted takeover after relaunch.
    static let androidSetup = AndroidEmulatorSetup(
        journal: CertificateAuthority.applicationSupport.appendingPathComponent("AndroidSetup/takeover.json"),
        command: { try adb($0) }
    )

    static func androidEmulatorDetails(certificatePath: String) throws -> [AndroidEmulatorSetup.Device] {
        let hash = try androidCertificateHash(certificatePath: certificatePath)
        return try androidSetup.devices(certificateHash: hash)
    }

    static func overrideAndroidEmulators(certificatePath: String, port: UInt16,
                                         installCertificate: Bool = true, setProxy: Bool = true,
                                         reboot: Bool = false) throws -> [String] {
        try withAndroidCertificateSnapshot(certificatePath) { snapshot in
            let hash = try androidCertificateHash(certificatePath: snapshot.path)
            let devices = try androidSetup.devices(certificateHash: hash)
            return try androidSetup.override(devices, certificate: snapshot,
                certificateHash: hash, proxy: "10.0.2.2:\(port)",
                installCertificate: installCertificate, setProxy: setProxy, reboot: reboot)
        }
    }

    /// Freeze bytes before computing the Android subject hash or waiting for adb.
    private static func withAndroidCertificateSnapshot<T>(_ path: String, operation: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirror-Android-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = directory.appendingPathComponent("certificate.pem")
        try PrivateAppFile.write(Data(contentsOf: URL(fileURLWithPath: path)), to: snapshot)
        return try operation(snapshot)
    }

}
