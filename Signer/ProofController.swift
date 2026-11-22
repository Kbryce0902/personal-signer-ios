import Foundation
import Minimuxer
import SideSign
import SwiftUI
import UserNotifications

enum SetupFile: String, Identifiable {
    case pairing, ipa, certificate

    var id: String { rawValue }
}

@MainActor
final class ProofController: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Open this build on the iPhone with its USB-installed development profile."
    @Published private(set) var pairingImported = false
    @Published private(set) var signedIn = false
    @Published private(set) var apps: [ImportedApp] = []
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
            let apple = AppleSigning()
            let device = PairedDevice(files: files)
            let profile = try Self.runningProfile()
            let identity = try AppIdentity(profile: profile)
            let saved = try files.readState()
            ownExpiration = profile.expirationDate
            pairingImported = device.hasPairing
            signedIn = try apple.isSignedIn(teamID: identity.teamID)
            apps = try files.importedApps()
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
            case .ipa:
                let signer = try AppIdentity(profile: Self.runningProfile())
                let app = try runtime.files.importIPA(from: url, signerBundleID: signer.bundleID)
                apps = try runtime.files.importedApps()
                status = "\(app.name) is ready to sign."
            case .certificate:
                let bytes = try ProofFiles.readImport(url, maxBytes: 1024 * 1024)
                let identity = try AppIdentity(profile: Self.runningProfile())
                try await runtime.apple.importCertificate(data: bytes, password: certificatePassword, teamID: identity.teamID)
                status = "Personal Team development certificate stored in the Keychain."
            }
        }
    }

    func checkAppleSetup() async {
        await run("Checking local Apple authentication…", fallback: "The local Apple authentication check failed.") { runtime in
            try await runtime.apple.checkLocalAuthentication()
            status = "Local Apple authentication is ready. Sign in with your Apple Account."
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

    var installedApps: [ImportedApp] {
        apps.filter { state.receipt(for: $0.bundleID) != nil }
    }

    func install(_ app: ImportedApp, peer: String, port: String) async {
        await run("Connecting to this iPhone…", fallback: "The install was not confirmed. Check the local tunnel and Apple sign-in, then retry.") { runtime in
            let profile = try Self.runningProfile()
            let udid = try await connect(runtime, peer: peer, port: port, profile: profile)
            try await install(app, runtime: runtime, udid: udid, signer: AppIdentity(profile: profile))
        }
    }

    func refreshAll(peer: String, port: String) async {
        await run("Connecting to this iPhone…", fallback: "Refresh All stopped. Retry after resolving the reported issue.") { runtime in
            let profile = try Self.runningProfile()
            let signer = try AppIdentity(profile: profile)
            let udid = try await connect(runtime, peer: peer, port: port, profile: profile)
            for app in installedApps {
                try await install(app, runtime: runtime, udid: udid, signer: signer)
            }
            try await performInstall(
                runtime, build: Self.runningBuildNumber(), bundleID: signer.bundleID,
                name: "Personal Signer", udid: udid, signerIdentity: signer,
                expectedIdentity: signer, installed: nil, sourceBundleID: nil
            )
        }
    }

    private func install(_ app: ImportedApp, runtime: Runtime, udid: String, signer: AppIdentity) async throws {
        let receipt = state.receipt(for: app.bundleID)
        let pending = state.pendingInstall(for: app.bundleID)
        let pinned = receipt?.identity ?? pending?.identity
        status = "Checking the installed identity for \(app.name)…"
        let installed: InstalledApp?
        let targetID: String
        if let pinned {
            targetID = pinned.bundleID
            installed = try await runtime.device.installedApp(bundleID: targetID)
        } else {
            let alternateID = app.bundleID + "." + signer.teamID
            let original = try await runtime.device.installedApp(bundleID: app.bundleID)
            let suffixed = ImportedApp.supportsBundleID(alternateID)
                ? try await runtime.device.installedApp(bundleID: alternateID) : nil
            guard original == nil || suffixed == nil else {
                throw ProofIssue.message("Two installed copies of \(app.name) match this IPA. Import the IPA with the exact installed bundle identifier.")
            }
            installed = original ?? suffixed
            targetID = installed?.bundleID ?? app.bundleID
            if let installed, installed.applicationID?.isEmpty != false {
                throw ProofIssue.message("iOS did not report the signing identity for \(app.name). Keep the installed copy and use its original signing tool for updates.")
            }
        }
        guard targetID == app.bundleID || targetID == app.bundleID + "." + signer.teamID,
              targetID != signer.bundleID else {
            throw ProofIssue.message("The installed bundle identifier differs from the expected identity for \(app.name).")
        }
        if let installed {
            guard installed.bundleID == targetID,
                  installed.teamID.map({ $0 == signer.teamID }) ?? true,
                  installed.applicationID.map({ id in
                      id.hasSuffix("." + targetID) && (pinned == nil || pinned?.applicationID == id)
                  }) ?? true else {
                throw ProofIssue.message("The installed copy of \(app.name) has a different signing identity. Keep it installed and use the original Apple Account and bundle ID.")
            }
            if let raw = installed.build, let current = AppBuildNumber(raw), app.build < current {
                throw ProofIssue.message("Import build \(current) or newer for \(app.name).")
            }
        }
        if let minimum = [receipt?.build, pending?.build].compactMap({ $0 }).max(), app.build < minimum {
            throw ProofIssue.message("Import build \(minimum) or newer for \(app.name).")
        }

        try await performInstall(
            runtime, build: app.build, bundleID: targetID, name: app.name, udid: udid,
            signerIdentity: signer, expectedIdentity: pinned, installed: installed, sourceBundleID: app.bundleID
        )
    }

    private func performInstall(
        _ runtime: Runtime, build: AppBuildNumber, bundleID: String, name: String, udid: String,
        signerIdentity: AppIdentity, expectedIdentity: AppIdentity?, installed: InstalledApp?,
        sourceBundleID: String?
    ) async throws {
        let isSigner = sourceBundleID == nil
        status = "Preparing \(name)…"
        let files = runtime.files
        let stage = try files.newStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stage) }

        let app: URL
        if let sourceBundleID {
            let info = try files.inspectIPA(at: files.ipaURL(for: sourceBundleID), extractTo: stage)
            guard info.build == build, info.bundleID == sourceBundleID else {
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
            if sourceBundleID != bundleID {
                try files.setBundleID(bundleID, for: app)
            }
        } else {
            app = stage.appendingPathComponent("PersonalSigner.app", isDirectory: true)
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: app)
        }

        let stamp = UUID()
        try ProofFiles.write(Data(stamp.uuidString.utf8), to: app.appendingPathComponent(ProofFiles.stampName))
        status = "Obtaining Apple provisioning and signing \(name)…"
        let profile = try await runtime.apple.sign(
            app: app, name: name, bundleID: bundleID, udid: udid,
            bootstrapIdentity: signerIdentity, existingIdentity: expectedIdentity,
            installedApplicationID: installed?.applicationID
        )
        let pending = PendingInstall(
            stamp: stamp, isSigner: isSigner, identity: try AppIdentity(profile: profile),
            build: build, profileID: profile.uuid, expiresAt: profile.expirationDate,
            previousExpiration: sourceBundleID.flatMap { state.receipt(for: $0)?.expiresAt } ?? (isSigner ? ownExpiration : nil),
            sourceBundleID: sourceBundleID
        )
        let stagingID = "dev.kellen.personalsigner." + stamp.uuidString
        status = "Sending \(name) to the paired installer…"
        try await runtime.device.stage(app, as: stagingID)
        var next = state
        if let sourceBundleID {
            next.setPending(pending, for: sourceBundleID)
        } else {
            next.pending = pending
        }
        try saveState(next, files: files)
        status = "Waiting for iOS to install \(name)…"
        try await runtime.device.install(stagingID: stagingID, appName: app.lastPathComponent)

        guard let sourceBundleID else {
            waitingForRelaunch = true
            status = "iOS reported completion. Reopen Personal Signer to verify the running copy."
            return
        }
        next.record(pending.receipt(), for: sourceBundleID)
        next.setPending(nil, for: sourceBundleID)
        try saveState(next, files: files)
        await scheduleReminders(name: name, id: sourceBundleID, expiration: pending.expiresAt)
        if let previous = pending.previousExpiration, pending.expiresAt <= previous {
            status = "iOS confirmed \(name). The profile expiration didn't advance."
        } else {
            status = "iOS confirmed \(name). Open it to verify the installed copy."
        }
    }

    private func checkPreviousInstall(profile: ProvisioningProfile, files: ProofFiles) {
        guard let pending = state.pending else {
            if pairingImported && signedIn {
                status = "Ready to install or refresh apps."
            } else {
                status = "Import the pairing record and check Apple setup to begin."
            }
            return
        }
        guard pending.isSigner else {
            status = "An app installation was interrupted. Retry that app with the same build."
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

    func enableReminders() async {
        guard !busy else { return }
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                status = "Allow Personal Signer notifications in iPhone Settings to receive expiration reminders."
                return
            }
            await updateReminders()
            status = "Expiration reminders are enabled."
        } catch {
            status = "Expiration reminders could not be enabled."
        }
    }

    func updateReminders() async {
        if let ownExpiration {
            await scheduleReminders(name: "Personal Signer", id: "signer", expiration: ownExpiration)
        }
        for app in installedApps {
            if let receipt = state.receipt(for: app.bundleID) {
                await scheduleReminders(name: app.name, id: app.bundleID, expiration: receipt.expiresAt)
            }
        }
    }

    private func scheduleReminders(name: String, id: String, expiration: Date) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let hours = [48, 24]
        let requestIDs = hours.map { "expires.\(id).\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: requestIDs)
        for (hoursRemaining, requestID) in zip(hours, requestIDs) {
            let interval = expiration.timeIntervalSinceNow - Double(hoursRemaining * 3600)
            guard interval >= 1 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(name) expires in \(hoursRemaining) hours"
            content.body = "Open Personal Signer to refresh it."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: trigger))
        }
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

    private static func runningBuildNumber() throws -> AppBuildNumber {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let build = AppBuildNumber(raw) else {
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
                return "The app’s bundle ID is unavailable to this Personal Team. Check that the same signed identity is in use."
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
            case .lookupApps:
                return "Couldn't check the installed app identity. Unlock the iPhone and reconnect LocalDevVPN before retrying."
            case .installApp:
                return "iOS didn't confirm installation. Check Developer Mode, developer trust, the three-app limit, and the existing app's signing identity. You can retry this build."
            default:
                return fallback
            }
        }
        return fallback
    }
}
