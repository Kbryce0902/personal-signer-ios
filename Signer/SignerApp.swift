import Foundation
import SideSign
import SwiftUI
import UniformTypeIdentifiers

@main
struct SignerApp: App {
    var body: some Scene {
        WindowGroup { SignerView() }
    }
}

@MainActor
private struct SignerView: View {
    @StateObject private var proof = ProofController()
    @StateObject private var discovery = PairingDiscovery()
    @AppStorage("tunnel-peer") private var peer = "10.7.0.1"
    @AppStorage("pairing-port") private var port = "49152"
    @State private var appleID = ""
    @State private var password = ""
    @State private var code = ""
    @State private var certificatePassword = ""
    @State private var fileKind: SetupFile?
    @State private var showImporter = false
    @State private var showDiscovery = false
    @State private var showAccount = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    if proof.busy { ProgressView() }
                    Text(proof.status)
                        .accessibilityIdentifier("proof-status")
                    if let expiration = proof.ownExpiration {
                        LabeledContent("Signer expires") { Text(expiration, format: .dateTime) }
                    }
                    if let bundleID = Bundle.main.bundleIdentifier {
                        Text(bundleID).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let verified = proof.state.signer {
                        LabeledContent("Signer confirmed") { Text(verified.confirmedAt, format: .dateTime) }
                    }
                }

                if let request = proof.verification {
                    verificationSection(request)
                }

                Section("Device connection") {
                    Button(proof.pairingImported ? "Replace Pairing Record" : "Import Pairing Record") {
                        importFile(.pairing)
                    }
                    TextField("LocalDevVPN peer", text: $peer)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    TextField("Remote Pairing port", text: $port)
                        .keyboardType(.numberPad)
                    Button("Find Remote Pairing Ports") { showDiscovery = true }
                    Button("Check Connection") {
                        Task { await proof.verifyConnection(peer: peer, port: port) }
                    }
                    .disabled(!proof.pairingImported)
                }
                .disabled(disabled)

                Section("Apple Account") {
                    Button(proof.adiImported ? "Replace AppleADI.zip" : "Import AppleADI.zip") {
                        importFile(.authentication)
                    }
                    Button(proof.signedIn ? "Sign In Again" : "Sign In") { showAccount = true }
                        .disabled(!proof.adiImported)
                    if proof.signedIn {
                        SecureField("Certificate password, if needed", text: $certificatePassword)
                        Button("Import My Development Certificate") { importFile(.certificate) }
                    }
                }
                .disabled(disabled)

                Section("Storage Probe") {
                    Button("Import Test IPA") { importFile(.probe) }
                    if let selection = proof.selection {
                        LabeledContent("Selected", value: "\(selection.name) · Build \(selection.build)")
                        Text(selection.bundleID).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let receipt = proof.state.probe {
                        LabeledContent("Installed build", value: String(receipt.build))
                        LabeledContent("Expires") { Text(receipt.expiresAt, format: .dateTime) }
                        LabeledContent("Last confirmed") { Text(receipt.confirmedAt, format: .dateTime) }
                    }
                    Button("Install or Refresh Probe") {
                        Task { await proof.installProbe(peer: peer, port: port, refreshSigner: false) }
                    }
                    .disabled(!canInstall)
                    Button("Refresh Probe, Then Signer") {
                        Task { await proof.installProbe(peer: peer, port: port, refreshSigner: true) }
                    }
                    .disabled(!canInstall || proof.state.probe == nil)
                }
                .disabled(disabled)
            }
            .navigationTitle("Personal Signer")
            .task { proof.start() }
            .sheet(isPresented: $showDiscovery) { discoverySheet }
            .sheet(isPresented: $showAccount, onDismiss: { password = "" }) { accountSheet }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
                guard let kind = fileKind else { return }
                fileKind = nil
                if case .success(let url) = result {
                    let secret = kind == .certificate ? certificatePassword : ""
                    if kind == .certificate { certificatePassword = "" }
                    Task { await proof.importFile(kind, url: url, certificatePassword: secret) }
                }
            }
        }
    }

    private var disabled: Bool {
        !proof.ready || proof.busy || proof.waitingForRelaunch
    }

    private var canInstall: Bool {
        proof.pairingImported && proof.signedIn && proof.selection != nil
    }

    private func importFile(_ kind: SetupFile) {
        fileKind = kind
        showImporter = true
    }

    private var discoverySheet: some View {
        NavigationStack {
            List {
                if discovery.ports.isEmpty {
                    Text("No Remote Pairing ports found yet. Keep Wi-Fi and LocalDevVPN connected and allow Local Network access.")
                }
                ForEach(discovery.ports, id: \.self) { candidate in
                    Button(String(candidate)) {
                        port = String(candidate)
                        showDiscovery = false
                    }
                }
            }
            .navigationTitle("Remote Pairing")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showDiscovery = false }
                }
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private var accountSheet: some View {
        NavigationStack {
            Form {
                TextField("Apple Account", text: $appleID)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password).textContentType(.password)
                Text("This build requires the account that installed the signer over USB.")
                    .font(.footnote)
            }
            .navigationTitle("Apple Sign-In")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAccount = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        let account = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
                        let secret = password
                        appleID = ""
                        password = ""
                        showAccount = false
                        Task { await proof.signIn(appleID: account, password: secret) }
                    }
                    .disabled(appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                }
            }
        }
    }

    private func verificationSection(_ request: TwoFactorRequest) -> some View {
        Section("Apple verification") {
            if case .selectDeliveryMethod(_, let phones) = request {
                Button("Send to Trusted Device") { proof.answerVerification(.requestTrustedDevice) }
                ForEach(phones) { phone in
                    Button("Text \(phone.number)") { proof.answerVerification(.requestSMS(phoneID: phone.id)) }
                }
            } else {
                if request.error != nil { Text("Apple rejected that verification code.") }
                TextField("Verification code", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                Button("Verify") {
                    let value = code
                    code = ""
                    proof.answerVerification(.verificationCode(value))
                }
                .disabled(code.count != 6 || !code.allSatisfy { "0123456789".contains($0) })
            }
            Button("Cancel Sign-In", role: .cancel) {
                code = ""
                proof.answerVerification(.cancel)
            }
        }
    }
}

@MainActor
private final class PairingDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var ports: [Int] = []
    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []

    func start() {
        stop()
        ports = []
        let finder = NetServiceBrowser()
        finder.delegate = self
        browser = finder
        finder.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
    }

    func stop() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        for service in resolving {
            service.delegate = nil
            service.stop()
        }
        resolving.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard self.browser === browser else { return }
        resolving.append(service)
        service.delegate = self
        service.resolve(withTimeout: 4)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard browser != nil, (1...65_535).contains(sender.port), !ports.contains(sender.port) else { return }
        ports = (ports + [sender.port]).sorted()
    }
}
