import Combine
import Foundation
@preconcurrency import NetworkExtension
import SystemExtensions

@MainActor
final class TransparentProxyController: NSObject, ObservableObject, @preconcurrency OSSystemExtensionRequestDelegate {
    enum State: Equatable {
        case idle
        case activating
        case awaitingApproval
        case connecting
        case running
        case stopping
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    static var isAvailable: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
            .appendingPathComponent("\(identifier).transparent-proxy.systemextension", isDirectory: true)
        return Bundle(url: url)?.bundleIdentifier == "\(identifier).transparent-proxy"
    }

    private(set) var needsStop = false

    private var manager: NETransparentProxyManager?
    private var cleanupPending = false
    private var startTask: Task<Void, Error>?
    private var stopTask: Task<Void, Error>?
    private var activationRequest: OSSystemExtensionRequest?
    private var activationContinuation: CheckedContinuation<Void, Error>?
    private var statusObserver: NSObjectProtocol?

    func start(port: UInt16, token: String) async throws {
        try Task.checkCancellation()
        guard startTask == nil, stopTask == nil, !needsStop else {
            throw Failure(OperationIssue.transparentProxyControllerStopTheCurrentTransparentCaptureFirst)
        }
        guard Self.isAvailable, let hostID = Bundle.main.bundleIdentifier else {
            let failure = Failure(OperationIssue.transparentProxyControllerThisAppBundleDoesNotContainTheTransparent)
            state = .failed(failure.operationIssue.localizedPresentation)
            throw failure
        }
        guard port != 0, !token.isEmpty else {
            let failure = Failure(OperationIssue.transparentProxyControllerTheLocalListenerConfigurationForTransparentCaptureIs)
            state = .failed(failure.operationIssue.localizedPresentation)
            throw failure
        }

        needsStop = true
        state = .activating
        let task = Task {
            defer { startTask = nil }
            try await startCapture(hostID: hostID, port: port, token: token)
        }
        startTask = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func stop() async throws {
        if let task = stopTask {
            return try await task.value
        }
        guard needsStop else {
            state = .idle
            return
        }
        try await stopCapture(endingIn: .idle)
    }

    func recover() async {
        guard Self.isAvailable, startTask == nil, stopTask == nil, !needsStop else { return }
        cleanupPending = true
        try? await stopCapture(endingIn: .idle)
    }

    private func startCapture(hostID: String, port: UInt16, token: String) async throws {
        do {
            try await activateExtension("\(hostID).transparent-proxy")
            try Task.checkCancellation()

            state = .connecting
            cleanupPending = true
            try await cleanUpProfiles(hostID: hostID)
            try Task.checkCancellation()

            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = "\(hostID).transparent-proxy"
            configuration.serverAddress = "127.0.0.1"
            configuration.providerConfiguration = [
                "port": Int(port),
                "token": token,
                "hostBundleIdentifier": hostID,
            ]

            let profile = NETransparentProxyManager()
            profile.localizedDescription = Strings.Errors.transparentProxyControllerProxymirrorTransparentCapture
            profile.protocolConfiguration = configuration
            profile.isEnabled = true
            manager = profile
            cleanupPending = true
            try await profile.saveToPreferences()
            try Task.checkCancellation()
            try await profile.loadFromPreferences()
            try Task.checkCancellation()
            try profile.connection.startVPNTunnel()
            try await waitForConnection(profile.connection, connected: true)
            try Task.checkCancellation()
            observeStatus()
            if isConnectionStopping {
                throw Failure(OperationIssue.transparentProxyControllerTheTransparentProxyConnectionWasDisconnected)
            }
            state = .running
        } catch {
            let failure = issue(for: error, operation: .transparentProxyControllerUnableToStartTransparentCapture)
            if stopTask == nil {
                let finalState: State = error is CancellationError ? .idle : .failed(failure.localizedPresentation)
                do {
                    try await stopCapture(endingIn: finalState, waitForStart: false)
                } catch {
                    let cleanup = issue(for: error, operation: .transparentProxyControllerUnableToStopTransparentCapture)
                    let combined = Failure(OperationIssue.transparentCaptureCleanupFailed(failure.diagnostic, cleanup.diagnostic)
                        .withPresentation { Strings.Errors.transparentCaptureCleanupFailed(failure.localizedPresentation, cleanup.localizedPresentation) })
                    state = .failed(combined.operationIssue.localizedPresentation)
                    throw combined
                }
            }
            if error is CancellationError { throw error }
            throw Failure(failure)
        }
    }

    private func stopCapture(endingIn finalState: State, waitForStart: Bool = true) async throws {
        if let task = stopTask {
            return try await task.value
        }
        needsStop = true
        state = .stopping
        let task = Task {
            defer { stopTask = nil }
            if waitForStart, let pendingStart = startTask {
                pendingStart.cancel()
                if let request = activationRequest {
                    finishActivation(request, with: .failure(CancellationError()))
                }
                _ = await pendingStart.result
            }
            do {
                if let hostID = Bundle.main.bundleIdentifier {
                    try await cleanUpProfiles(hostID: hostID)
                }
                needsStop = false
                state = finalState
            } catch {
                let failure = Failure(issue(for: error, operation: .transparentProxyControllerUnableToStopTransparentCapture))
                state = .failed(failure.operationIssue.localizedPresentation)
                throw failure
            }
        }
        stopTask = task
        try await task.value
    }

    private func cleanUpProfiles(hostID: String) async throws {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
            statusObserver = nil
        }
        guard cleanupPending else { return }
        if let profile = manager {
            try await stopConnection(profile.connection)
        }
        let profiles = try await NETransparentProxyManager.loadAllFromPreferences()
        for profile in profiles where ownsProfile(profile, hostID: hostID) {
            try await stopConnection(profile.connection)
            try await profile.removeFromPreferences()
        }
        manager = nil
        cleanupPending = false
    }

    private func ownsProfile(_ profile: NETransparentProxyManager, hostID: String) -> Bool {
        guard let configuration = profile.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return configuration.providerBundleIdentifier == "\(hostID).transparent-proxy"
            && configuration.providerConfiguration?["hostBundleIdentifier"] as? String == hostID
    }

    private func stopConnection(_ connection: NEVPNConnection) async throws {
        guard connection.status != .invalid else { return }
        connection.stopVPNTunnel()
        try await waitForConnection(connection, connected: false)
    }

    private func waitForConnection(_ connection: NEVPNConnection, connected: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        var beganConnecting = false
        while ContinuousClock.now < deadline {
            let status = connection.status
            switch (connected, status) {
            case (true, .connected), (false, .invalid), (false, .disconnected):
                return
            case (true, .connecting), (true, .reasserting):
                beganConnecting = true
            case (true, .invalid), (true, .disconnecting):
                throw Failure(OperationIssue.transparentProxyControllerUnableToEstablishTheTransparentProxyConnection)
            case (true, .disconnected) where beganConnecting:
                throw Failure(OperationIssue.transparentProxyControllerUnableToEstablishTheTransparentProxyConnection)
            default:
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(connected ? OperationIssue.transparentProxyControllerTimedOutWaitingForTheTransparentProxyConnection : OperationIssue.transparentProxyControllerTimedOutWaitingForTheTransparentProxyTo)
    }

    private var isConnectionStopping: Bool {
        guard let status = manager?.connection.status else { return true }
        return status == .invalid || status == .disconnected || status == .disconnecting
    }

    private func observeStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .running, self.isConnectionStopping else { return }
                try? await self.stopCapture(endingIn: .failed(OperationIssue.transparentProxyControllerTheTransparentProxyConnectionWasDisconnected))
            }
        }
    }

    private func activateExtension(_ identifier: String) async throws {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        let requestID = ObjectIdentifier(request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                activationRequest = request
                activationContinuation = continuation
                request.delegate = self
                OSSystemExtensionManager.shared.submitRequest(request)
            }
        } onCancel: {
            Task { @MainActor in
                if let pending = self.activationRequest, ObjectIdentifier(pending) == requestID {
                    self.finishActivation(pending, with: .failure(CancellationError()))
                }
            }
        }
    }

    private func finishActivation(_ request: OSSystemExtensionRequest, with result: Result<Void, Error>) {
        guard request === activationRequest, let continuation = activationContinuation else { return }
        activationRequest = nil
        activationContinuation = nil
        continuation.resume(with: result)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard request === activationRequest, stopTask == nil else { return }
        state = .awaitingApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            finishActivation(request, with: .success(()))
        case .willCompleteAfterReboot:
            finishActivation(request, with: .failure(Failure(OperationIssue.transparentProxyControllerRestartYourMacToFinishActivatingTheTransparent)))
        @unknown default:
            finishActivation(request, with: .failure(Failure(OperationIssue.transparentProxyControllerTheSystemExtensionReturnedAnUnknownActivationState)))
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        finishActivation(request, with: .failure(Failure(OperationIssue.transparentProxyControllerUnableToActivateTheTransparentProxySystemExtension(String(error.localizedDescription)))))
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        request === activationRequest ? .replace : .cancel
    }

    private func issue(for error: Error, operation: OperationIssue) -> OperationIssue {
        if let failure = error as? OperationIssueProviding { return failure.operationIssue }
        if error is CancellationError { return .transparentProxyControllerTransparentCaptureWasCancelled }
        let systemError = error as NSError
        let domain = systemError.domain
        let code = systemError.code
        return OperationIssue.transparentSystemOperationFailed(operation.diagnostic, domain, code)
            .withPresentation { Strings.Errors.transparentSystemOperationFailed(operation.localizedPresentation, domain, code) }
    }

    private struct Failure: LocalizedError, OperationIssueProviding {
        let operationIssue: OperationIssue
        init(_ issue: OperationIssue) { operationIssue = issue }
        init(_ message: String) { operationIssue = .technical(message) }
        var message: String { operationIssue.diagnostic }
        var text: String { operationIssue.diagnostic }
        var errorDescription: String? { operationIssue.diagnostic }
    }
}
