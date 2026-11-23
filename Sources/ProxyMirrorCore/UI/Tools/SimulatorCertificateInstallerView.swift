import AppKit
import SwiftUI

@MainActor
struct SimulatorCertificateInstallerView: View {
    let initialPlatform: String
    @State private var useCustomSet = false
    @State private var customSet: URL?
    @State private var platform = "all"
    @State private var devices: [SimulatorCertificateInstaller.Device] = []
    @State private var selected = Set<String>()
    @State private var loading = false
    @State private var installing = false
    @State private var feedback: String?
    @State private var results: [String] = []
    @State private var operation: Task<Void, Never>?

    private let platforms = ["all", "iOS", "watchOS", "tvOS", "visionOS"]
    private var deviceSet: URL? { useCustomSet ? customSet : nil }
    private var visibleDevices: [SimulatorCertificateInstaller.Device] { devices.filter { $0.matches(platform: platform) } }
    private var busy: Bool { loading || installing }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.Tools.installTheCurrentProxymirrorCaOnSelectedSimulators).font(.headline)
            sourceSelector
            HStack {
                Picker(Strings.Tools.platform, selection: $platform) {
                    ForEach(platforms, id: \.self) { Text($0 == "all" ? Strings.Tools.allPlatforms : $0).tag($0) }
                }.frame(width: 190).disabled(busy)
                Spacer()
                Button(Strings.Tools.refreshDevices) { refresh() }.disabled(busy || (useCustomSet && customSet == nil))
                if loading { ProgressView().controlSize(.small) }
            }
            List {
                ForEach(visibleDevices) { device in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(Strings.Tools.select1(String(describing: device.name)), isOn: Binding(get: { selected.contains(device.id) }, set: { value in
                            if value { selected.insert(device.id) } else { selected.remove(device.id) }
                        })).labelsHidden().disabled(busy || !device.isBooted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).fontWeight(.medium)
                            Text("\(device.runtimeName) · \(device.id)")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Label(device.localizedState, systemImage: device.isBooted ? "play.circle.fill" : "stop.circle")
                            .font(.caption).foregroundStyle(device.isBooted ? Color.green : .secondary)
                    }.padding(.vertical, 3)
                }
                if !loading && visibleDevices.isEmpty {
                    Text(Strings.Tools.noMatchingAvailableSimulatorsWereFoundInThisDevice)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(minHeight: 200, idealHeight: 250)
            Text(Strings.Tools.onlyBootedDevicesReceiveAddRootCertDevicesAre)
                .font(.caption).foregroundStyle(.secondary)
            if let feedback { Text(feedback).font(.caption).textSelection(.enabled) }
            if !results.isEmpty {
                ScrollView { Text(results.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
            }
            HStack {
                Button(Strings.Tools.selectBootedDevices) { selected = Set(visibleDevices.filter(\.isBooted).map(\.id)) }.disabled(busy)
                Button(Strings.Tools.clearSelection) { selected.removeAll() }.disabled(busy || selected.isEmpty)
                Spacer()
                if installing {
                    ProgressView().controlSize(.small)
                    Button(Strings.Tools.cancelRemainingInstallations) { operation?.cancel(); feedback = Strings.Tools.stopAfterTheCurrentDeviceCommandFinishesDoNot }
                }
                Button(Strings.Tools.installOnDevices(Int(selected.count))) { install() }
                    .buttonStyle(.borderedProminent).disabled(busy || selected.isEmpty)
            }
        }
        .padding(18).frame(width: 780)
        .onAppear {
            platform = platforms.contains(initialPlatform) ? initialPlatform : "all"
            refresh()
        }
        .onChange(of: platform) { _ in selected.formIntersection(visibleDevices.map(\.id)) }
        .onDisappear { operation?.cancel() }
    }

    private var sourceSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(Strings.Tools.deviceSet, selection: Binding(get: { useCustomSet }, set: { value in
                useCustomSet = value; devices = []; selected.removeAll(); feedback = nil
                if !value || customSet != nil { refresh() }
            })) {
                Text(Strings.Tools.standardSimulatorDeviceSet).tag(false)
                Text(Strings.Tools.chooseDeviceSetManuallyIncludingPreview).tag(true)
            }.pickerStyle(.segmented)
            if useCustomSet {
                HStack {
                    Text(customSet?.path ?? Strings.Tools.noDirectorySelected).font(.caption).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button(Strings.Tools.chooseDirectory, action: chooseDeviceSet)
                }
                Text(Strings.Tools.forXcodePreviewChooseItsActualDeviceSetDirectory)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(busy)
    }

    private func chooseDeviceSet() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = Strings.Tools.useThisDeviceSet
        panel.message = Strings.Tools.chooseAnExistingSimulatorDeviceSetDirectoryContainingDevice
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SimulatorCertificateInstaller.validateDeviceSet(url)
            customSet = url; useCustomSet = true; selected.removeAll(); devices = []; refresh()
        } catch { feedback = LocalizedErrorPresentation.message(for: error) }
    }

    private func refresh() {
        guard !busy, !useCustomSet || customSet != nil else { return }
        let set = deviceSet
        loading = true; feedback = nil; results = []
        operation = Task {
            defer { loading = false; operation = nil }
            do {
                let listed = try await Task.detached(priority: .userInitiated) {
                    try SimulatorCertificateInstaller.list(deviceSet: set)
                }.value
                guard !Task.isCancelled else { return }
                devices = listed
                selected.formIntersection(listed.filter(\.isBooted).map(\.id))
                feedback = Strings.Tools.foundAvailableDevicesSelectTheBootedDevicesOnWhich(Int(listed.count))
            } catch { devices = []; selected.removeAll(); feedback = LocalizedErrorPresentation.message(for: error) }
        }
    }

    private func install() {
        guard !busy else { return }
        let targets = devices.filter { selected.contains($0.id) && $0.isBooted }
        guard !targets.isEmpty else { return }
        let set = deviceSet
        installing = true; results = []; feedback = Strings.Tools.preparingTheCurrentCa
        operation = Task {
            defer { installing = false; operation = nil }
            do {
                let certificate = try await Task.detached(priority: .userInitiated) {
                    let pem = try CertificateAuthority.shared.caPEM()
                    let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirror-Simulator-CA-" + UUID().uuidString + ".pem")
                    try PrivateAppFile.write(Data(pem.utf8), to: snapshot)
                    return snapshot
                }.value
                defer { try? FileManager.default.removeItem(at: certificate) }
                var successes = 0
                for device in targets {
                    try Task.checkCancellation()
                    feedback = Strings.Tools.installing12(String(describing: device.name), String(describing: device.runtimeName))
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try SimulatorCertificateInstaller.install(certificate: certificate, device: device, deviceSet: set)
                        }.value
                        successes += 1
                        results.append(Strings.Tools.step12SimctlInstalledTheCa(String(describing: device.name), String(describing: device.runtimeName)))
                    } catch { results.append(Strings.Tools.deviceInstallationFailure(device.name, LocalizedErrorPresentation.message(for: error))) }
                }
                feedback = Strings.Tools.installationFinishedOfDevicesSucceededSendATestRequest(Int(successes), Int(targets.count))
            } catch is CancellationError { feedback = Strings.Tools.furtherInstallationsStoppedCompletedDeviceInstallationsRemainInPlace }
            catch { feedback = LocalizedErrorPresentation.message(for: error) }
        }
    }
}
