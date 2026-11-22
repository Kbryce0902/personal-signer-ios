import Foundation
import Minimuxer
import SideSign
import SwiftUI

enum SetupFile: String, Identifiable {
    case pairing, authentication, probe, certificate

    var id: String { rawValue }
}

@MainActor
final class ProofController: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Open this build on the iPhone with its USB-installed development profile."
    @Published private(set) var pairingImported = false
    @Published private(set) var adiImported = false
    @Published private(set) var signedIn = false
    @Published private(set) var selection: ProbeBuild?
    @Published private(set) var state = ProofState()
    @Published private(set) var ownExpiration: Date?
    @Published private(set) var verification: TwoFactorRequest?
    @Published private(set) var waitingForRelaunch = false

    private struct Runtime {
        let files: ProofFiles
        let apple: AppleSigning
        let device: PairedDevice
    }

    private var runtime: Runtime?
    private var verificationContinuation: CheckedContinuation<TwoFactorResponse, Never>?

    func start() {
        guard runtime == nil else { return }
        do {
            let files = try ProofFiles()
            let apple = AppleSigning(files: files)
            let device = PairedDevice(files: files)
            let profile = try Self.runningProfile()
            let identity = try AppIdentity(profile: profile)
            let saved = try files.readState()
            ownExpiration = profile.expirationDate
            pairingImported = device.hasPairing
            adiImported = apple.hasLocalADI
            signedIn = try apple.isSignedIn(teamID: identity.teamID)
            if FileManager.default.fileExists(atPath: files.ipaURL.path) {
                selection = try? files.inspectProbe(at: files.ipaURL)
            }
            try files.cleanStagingOnLaunch()
            runtime = Runtime(files: files, apple: apple, device: device)
            ready = true
            state = saved
            checkPreviousInstall(profile: profile, files: files)
        } catch {
            status = Self.display(error, fallback: "The saved proof state could not be opened. Unlock the iPhone and reopen the signer.")
        }
    }

    func importFile(_ kind: SetupFile, url: URL, certificatePassword: String = "") async {
        await run("Reading the selected file…", fallback: "The file could not be imported. Check its format and try again.") { runtime in
            switch kind {
            case .pairing:
                try runtime.device.importPairing(from: url)
                pairingImported = true
                status = "Pairing record imported. Run Check Connection to verify it."
            case .authentication:
                try runtime.files.importADI(from: url)
                runtime.apple.invalidateADIClient()
                adiImported = runtime.apple.hasLocalADI
                status = "Local Apple authentication files imported."
            case .probe:
                selection = try runtime.files.importProbe(from: url)
                status = "Storage Probe is ready to sign."
            case .certificate:
                let bytes = try ProofFiles.readImport(url, maxBytes: 1024 * 1024)
                let identity = try AppIdentity(profile: Self.runningProfile())
                try await runtime.apple.importCertificate(data: bytes, password: certificatePassword, teamID: identity.teamID)
                status = "Personal Team development certificate stored in the Keychain."
            }
        }
    }

    func signIn(appleID: String, password: String) async {
        await run("Signing in with Apple…", fallback: "Apple sign-in failed. Verify the account and network, then retry.") { runtime in
            let identity = try AppIdentity(profile: Self.runningProfile())
            try await runtime.apple.signIn(appleID: appleID, password: password, teamID: identity.teamID) { [weak self] request in
                guard let self else { return .cancel }
                return await self.waitForVerification(request)
            }
            signedIn = true
            status = "Signed in to the same Personal Team that installed this signer."
        }
    }

    func answerVerification(_ response: TwoFactorResponse) {
        let continuation = verificationContinuation
        verificationContinuation = nil
        verification = nil
        continuation?.resume(returning: response)
    }

    func verifyConnection(peer: String, port: String) async {
        await run("Checking the local paired connection…", fallback: "The paired device didn't respond. Unlock the iPhone, connect LocalDevVPN and Wi-Fi, and check the Remote Pairing port.") { runtime in
            _ = try await connect(runtime, peer: peer, port: port, profile: Self.runningProfile())
            status = "This iPhone answered through the trusted local pairing."
        }
    }

    func installProbe(peer: String, port: String, refreshSigner: Bool) async {
        await run("Connecting to this iPhone…", fallback: "The install was not confirmed. Check the local tunnel and Apple sign-in before retrying the same build.") { runtime in
            let profile = try Self.runningProfile()
            let udid = try await connect(runtime, peer: peer, port: port, profile: profile)
            let signerIdentity = try AppIdentity(profile: profile)
            guard let selection else {
                throw ProofIssue.message("Import Storage Probe from Files first.")
            }
            let expected = state.probe?.identity ?? pendingIdentity(forSigner: false)
            let minimumBuild = state.probe?.build ?? 0
            guard selection.build >= minimumBuild else {
                throw ProofIssue.message("Choose the installed build or a newer Storage Probe build.")
            }

            try await performInstall(
                runtime, build: selection.build, bundleID: selection.bundleID,
                name: "Storage Probe", udid: udid, signerIdentity: signerIdentity,
                expectedIdentity: expected, isSigner: false
            )
            if refreshSigner {
                let ownBuild = try Self.runningBuildNumber()
                try await performInstall(
                    runtime, build: ownBuild, bundleID: signerIdentity.bundleID,
                    name: "Personal Signer", udid: udid, signerIdentity: signerIdentity,
                    expectedIdentity: signerIdentity, isSigner: true
                )
            }
        }
    }

    private func performInstall(
        _ runtime: Runtime, build: Int, bundleID: String, name: String, udid: String,
        signerIdentity: AppIdentity, expectedIdentity: AppIdentity?, isSigner: Bool
    ) async throws {
        status = "Preparing \(name)…"
        let files = runtime.files
        let stage = try files.newStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stage) }

        let app: URL
        if isSigner {
            app = stage.appendingPathComponent("PersonalSigner.app", isDirectory: true)
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: app)
        } else {
            let info = try files.inspectProbe(at: files.ipaURL, extractTo: stage)
            guard info.build == build, info.bundleID == bundleID else {
                throw ProofIssue.message("The selected IPA changed. Import the intended build again.")
            }
            let payload = stage.appendingPathComponent("Payload", isDirectory: true)
            let candidates = try FileManager.default.contentsOfDirectory(
                at: payload, includingPropertiesForKeys: [.isDirectoryKey]
            ).filter { $0.pathExtension == "app" }
            guard let only = candidates.first, candidates.count == 1 else {
                throw ProofIssue.message("The IPA must contain one app.")
            }
            app = only
        }

        let stamp = UUID()
        try ProofFiles.write(Data(stamp.uuidString.utf8), to: app.appendingPathComponent(ProofFiles.stampName))
        status = "Obtaining Apple provisioning and signing \(name)…"
        let profile = try await runtime.apple.sign(
            app: app, name: name, bundleID: bundleID, udid: udid,
            bootstrapIdentity: signerIdentity, existingIdentity: expectedIdentity
        )
        let pending = PendingInstall(
            stamp: stamp, isSigner: isSigner, identity: try AppIdentity(profile: profile),
            build: build, profileID: profile.uuid, expiresAt: profile.expirationDate,
            previousExpiration: isSigner ? ownExpiration : state.probe?.expiresAt
        )
        let stagingID = "dev.kellen.personalsigner." + stamp.uuidString
        status = "Sending \(name) to the paired installer…"
        try await runtime.device.stage(app, as: stagingID)
        var next = state
        next.pending = pending
        try saveState(next, files: files)
        status = "Waiting for iOS to install \(name)…"
        try await runtime.device.install(stagingID: stagingID, appName: app.lastPathComponent)

        if isSigner {
            waitingForRelaunch = true
            status = "iOS reported completion. Reopen Personal Signer to verify the running copy."
            return
        }
        next.probe = pending.receipt()
        next.pending = nil
        try saveState(next, files: files)
        if let previous = pending.previousExpiration, pending.expiresAt <= previous {
            status = "iOS confirmed installation. The profile expiration didn't advance."
        } else {
            status = "iOS confirmed Storage Probe. Open it to check the saved value and build."
        }
    }

    private func checkPreviousInstall(profile: ProvisioningProfile, files: ProofFiles) {
        guard let pending = state.pending else {
            if state.probe != nil {
                status = "Ready. The last confirmed Storage Probe install is shown below."
            } else if pairingImported && adiImported && signedIn {
                status = "Ready to check the paired connection and install Storage Probe."
            } else {
                status = "Import the pairing and local Apple authentication files to begin."
            }
            return
        }
        guard pending.isSigner else {
            status = "Storage Probe installation was interrupted. Retry the same build."
            return
        }
        let stampURL = Bundle.main.bundleURL.appendingPathComponent(ProofFiles.stampName)
        let actualStamp = try? String(contentsOf: stampURL, encoding: .utf8)
        guard actualStamp == pending.stamp.uuidString,
              (try? AppIdentity(profile: profile)) == pending.identity,
              (try? Self.runningBuildNumber()) == pending.build,
              profile.uuid == pending.profileID,
              profile.expirationDate == pending.expiresAt else {
            status = "The running signer doesn't match the pending self-refresh. Retry the queue or recover over USB."
            return
        }
        do {
            var next = state
            next.signer = pending.receipt()
            next.pending = nil
            try saveState(next, files: files)
            if let previous = pending.previousExpiration, pending.expiresAt <= previous {
                status = "Signer relaunch verified. The profile expiration didn't advance."
            } else {
                status = "Signer self-refresh verified after relaunch."
            }
        } catch {
            status = "The signer relaunched, but the receipt couldn't be saved. Reopen again to retry verification."
        }
    }

    private func connect(
        _ runtime: Runtime, peer: String, port: String, profile: ProvisioningProfile
    ) async throws -> String {
        let settings = try TunnelSettings(peer: peer, port: port)
        let device = try await runtime.device.connect(
            settings: settings, bootstrapProfile: profile, pinnedUDID: state.deviceUDID
        )
        if state.deviceUDID == nil {
            var next = state
            next.deviceUDID = device
            try saveState(next, files: runtime.files)
        }
        return device
    }

    private func pendingIdentity(forSigner: Bool) -> AppIdentity? {
        guard let pending = state.pending, pending.isSigner == forSigner else { return nil }
        return pending.identity
    }

    private func saveState(_ updated: ProofState, files: ProofFiles) throws {
        try files.save(updated)
        state = updated
    }

    private func waitForVerification(_ request: TwoFactorRequest) async -> TwoFactorResponse {
        await withCheckedContinuation { continuation in
            verificationContinuation = continuation
            verification = request
        }
    }

    private func run(
        _ heading: String, fallback: String, _ operation: (Runtime) async throws -> Void
    ) async {
        guard let runtime, !busy, !waitingForRelaunch else { return }
        busy = true
        status = heading
        defer { busy = false }
        do {
            try await operation(runtime)
        } catch {
            status = Self.display(error, fallback: fallback)
        }
    }

    private static func runningProfile() throws -> ProvisioningProfile {
        let url = Bundle.main.bundleURL.appendingPathComponent(ProofFiles.profileName)
        guard let profile = try? ProvisioningProfile(fileURL: url),
              profile.isFreeProvisioningProfile,
              profile.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw ProofIssue.message("Use the copy installed over USB with your free Apple Account development profile.")
        }
        return profile
    }

    private static func runningBuildNumber() throws -> Int {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let build = Int(raw), build > 0 else {
            throw ProofIssue.message("The running signer's build number is invalid.")
        }
        return build
    }

    private static func display(_ error: Error, fallback: String) -> String {
        if let issue = error as? ProofIssue { return issue.localizedDescription }
        if let issue = error as? DeveloperPortalError {
            switch issue {
            case .incorrectCredentials, .appSpecificPasswordRequired, .authenticationHandshakeFailed:
                return "Apple couldn't complete sign-in. Check the Apple Account, password, and verification method."
            case .maximumAppIDLimitReached:
                return "Apple's Personal Team App ID limit was reached. Wait for an App ID to expire or free one you own."
            case .tooManyCertificates:
                return "Apple's certificate limit was reached. Import the existing development certificate from your USB installer."
            case .bundleIdentifierUnavailable:
                return "The test bundle ID is unavailable to this Personal Team. Check that the same signed identity is in use."
            case .accountRepairRequired:
                return "Apple requires an account action. Complete it on Apple's account website and sign in again."
            case .userCancelled:
                return "Apple sign-in canceled."
            default:
                return fallback
            }
        }
        if let issue = error as? ServerError, case .underlyingError(let code, _) = issue,
           code == 401 || code == 403 {
            return "Apple rejected the session. Sign in again and retry."
        }
        if let issue = error as? MinimuxerError {
            let diagnostic = issue.localizedDescription.lowercased()
            if diagnostic.contains("1016") || diagnostic.contains("not been unlocked") {
                return "Unlock the iPhone, keep it awake, and retry."
            }
            if diagnostic.contains("maximum number of apps") || diagnostic.contains("0xe8008029") {
                return "This iPhone has reached Apple's three free-development app slots. Free a slot before trying again."
            }
            switch issue {
            case .pairingNotLoaded, .invalidPairing:
                return "The pairing couldn't be authenticated. Export a new Remote Pairing record over USB."
            case .noConnection, .notReachable, .noVPN, .invalidVPN, .noDevice:
                return "Connect LocalDevVPN and Wi-Fi, unlock the iPhone, and check the Remote Pairing port."
            case .installApp:
                return "iOS didn't confirm installation. Check Developer Mode, developer trust, the three-app limit, and the existing app's signing identity. You can retry this build."
            default:
                return fallback
            }
        }
        return fallback
    }
}
