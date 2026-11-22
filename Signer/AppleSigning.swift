import AnisetteKit
import AppleAuth
import Foundation
import SideSign

@MainActor
final class AppleSigning {
    private struct StoredSession: Codable {
        let auth: AuthSession
        let team: Team
    }

    private let portal = DeveloperPortal()
    private static let deviceStateKey = "apple-local-device-v2"
    private static let appleSessionKey = "apple-session-local-v2"

    init() {
        SideSignLogging.setLogging(false)
        AnisetteKitLogging.setLogging(false)
    }

    func isSignedIn(teamID: String) throws -> Bool {
        guard let bytes = try SignerKeychain.read(Self.appleSessionKey) else { return false }
        let current = try JSONDecoder().decode(StoredSession.self, from: bytes)
        return current.team.identifier == teamID && current.auth.session.isValid
    }

    func checkLocalAuthentication() async throws {
        do {
            _ = try await freshAnisette()
        } catch let issue as ProofIssue {
            throw issue
        } catch {
            throw ProofIssue.message("Local Apple authentication failed. \(Self.signInDetail(for: error))")
        }
    }

    func signIn(
        appleID: String, password: String, teamID: String,
        verification: @escaping DeveloperPortal.VerificationHandler
    ) async throws {
        var stage = "Local Apple authentication"
        do {
            let anisette = try await freshAnisette()
            stage = "Apple Account sign-in"
            let auth = try await portal.authenticate(
                appleID: appleID, password: password,
                anisetteData: anisette, xcodeVersion: "27.2",
                machinePassword: nil, accountRepairHandler: { _, _ in .cancel },
                verificationHandler: verification
            )
            stage = "Apple Personal Team lookup"
            let teams = try await portal.fetchTeams(for: auth.account, session: auth.session)
            guard let team = teams.first(where: { $0.identifier == teamID && $0.type == .free }) else {
                throw ProofIssue.message("Sign in with the free Apple Account that installed this signer over USB. The signing team doesn't match.")
            }
            stage = "Save Apple session"
            let bytes = try JSONEncoder().encode(StoredSession(auth: auth, team: team))
            try SignerKeychain.write(bytes, account: Self.appleSessionKey)
        } catch let issue as ProofIssue {
            throw issue
        } catch {
            throw ProofIssue.message("\(stage) failed. \(Self.signInDetail(for: error))")
        }
    }

    // These errors can include raw responses and request details. Display fixed messages and codes only.
    private static func signInDetail(for error: Error) -> String {
        if let issue = error as? AppleAuthError {
            let prefix = "Provisioning HTTP "
            if issue.message.hasPrefix(prefix),
               let status = Int(issue.message.dropFirst(prefix.count)),
               (100...599).contains(status) {
                return "Apple returned HTTP \(status) during local registration."
            }
            return "The local Apple authentication provider returned code \(issue.code)."
        }
        if let issue = error as? DeveloperPortalError {
            switch issue {
            case .incorrectCredentials:
                return "Apple rejected the credentials for this account."
            case .appSpecificPasswordRequired:
                return "Apple requested an app-specific password."
            case .requiresTwoFactorAuthentication, .incorrectVerificationCode, .invalid2FAResponse:
                return "Apple verification did not complete. Request a new code and check the selected verification method."
            case .accountRepairRequired:
                return "Apple requires you to complete an account action at account.apple.com."
            case .noTeams:
                return "Apple returned no developer teams for this account."
            case .tooManyAttempts:
                return "Apple limited sign-in attempts. Wait before trying again."
            case .authenticationHandshakeFailed:
                return "The authentication handshake could not be completed."
            case .invalidAnisetteData:
                return "The local Apple authentication data was incomplete."
            case .userCancelled:
                return "Apple sign-in was canceled."
            default:
                return "The developer service returned error code \((issue as NSError).code)."
            }
        }
        if let issue = error as? ServerError {
            switch issue {
            case .underlyingError(let code, _):
                return "Apple returned error code \(code)."
            case .badServerResponse(let reason, let payload):
                return responseDetail(reason) ?? responseDetail(payload) ?? "Apple returned an unexpected response."
            case .invalidResponseFormat(let payload), .missingKey(_, let payload):
                return responseDetail(payload) ?? "Apple returned an unexpected response."
            }
        }
        if let issue = error as? URLError {
            return "Network error \(issue.errorCode). Try signing in on Wi-Fi with LocalDevVPN disconnected."
        }
        return "System error code \((error as NSError).code)."
    }

    private static func responseDetail(_ body: String) -> String? {
        let prefix = String(body.prefix(4096))
        guard prefix.range(
            of: #"\b(?:HTTP(?:/[0-9.]+)?\s+503|503\s+(?:Service\s+)?(?:Temporarily\s+)?Unavailable)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else { return nil }
        return httpDetail(503)
    }

    private static func httpDetail(_ code: Int) -> String {
        if code == 503 {
            return "Apple returned HTTP 503 (service unavailable)."
        }
        return "The authentication request returned HTTP \(code)."
    }

    func importCertificate(data: Data, password: String, teamID: String) async throws {
        let context = try await signingSession(teamID: teamID)
        let key: KeyStore
        do {
            key = try KeyStore(p12Data: data, password: password.isEmpty ? nil : password)
        } catch {
            throw ProofIssue.message("The PKCS#12 file could not be opened. Check that it's your development certificate and the export password is correct.")
        }
        let certificates = try await portal.fetchCertificates(for: context.team, session: context.session)
        guard key.certificate.expiryDate > Date(),
              certificates.contains(where: { $0.serialNumber.caseInsensitiveCompare(key.certificate.serialNumber) == .orderedSame }) else {
            throw ProofIssue.message("This development certificate is expired or belongs to a different Apple team.")
        }
        try saveKey(key)
    }

    func sign(
        app: URL, name: String, bundleID: String, udid: String,
        bootstrapIdentity: AppIdentity, existingIdentity: AppIdentity?
    ) async throws -> ProvisioningProfile {
        let context = try await signingSession(teamID: bootstrapIdentity.teamID)
        let team = context.team
        let session = context.session

        let devices = try await portal.fetchDevices(for: team, types: .iPhone, session: session)
        if !devices.contains(where: { Self.sameUDID($0.identifier, udid) }) {
            _ = try await portal.registerDevice(
                name: "Personal Signer iPhone", identifier: udid, type: .iPhone, team: team, session: session
            )
        }

        let key = try await currentKey(team: team, session: session)
        let IDs = try await portal.fetchAppIDs(for: team, session: session)
        let appID: AppID
        if let existingID = IDs.first(where: { $0.bundleIdentifier == bundleID }) {
            appID = existingID
        } else {
            appID = try await portal.addAppID(
                withName: name, bundleIdentifier: bundleID, team: team, session: session
            )
        }

        let profile = try await portal.downloadProvisioningProfile(
            for: appID, isTeamProfile: true, subPlatform: nil, deviceType: .iPhone, team: team, session: session
        )
        let identity = try AppIdentity(profile: profile)
        guard profile.isFreeProvisioningProfile, profile.expirationDate > Date(),
              profile.entitlements["get-task-allow"] as? Bool == true,
              profile.deviceIDs.contains(where: { Self.sameUDID($0, udid) }),
              profile.certificates.contains(where: { $0.serialNumber.caseInsensitiveCompare(key.certificate.serialNumber) == .orderedSame }) else {
            throw ProofIssue.message("Apple returned a profile that doesn't authorize this iPhone and development certificate. Import your existing Personal Team certificate or try again after Apple updates the profile.")
        }
        guard identity.bundleID == bundleID, identity.teamID == bootstrapIdentity.teamID,
              existingIdentity == nil || existingIdentity == identity else {
            throw ProofIssue.message("The new app identity doesn't match the installed identity. Keep the original signed bundle ID and Apple team.")
        }

        try await AppBundleSigner(team: team, keyStore: key).signApp(
            at: app, provisioningProfiles: [profile]
        )
        return profile
    }

    static func sameUDID(_ left: String, _ right: String) -> Bool {
        left.replacingOccurrences(of: "-", with: "").caseInsensitiveCompare(
            right.replacingOccurrences(of: "-", with: "")
        ) == .orderedSame
    }

    private func signingSession(teamID: String) async throws -> (team: Team, session: Session) {
        guard let data = try SignerKeychain.read(Self.appleSessionKey) else {
            throw ProofIssue.message("Sign in with your Apple Account first.")
        }
        let stored = try JSONDecoder().decode(StoredSession.self, from: data)
        guard stored.auth.session.isValid else {
            throw ProofIssue.message("Your Apple sign-in has expired. Sign in again and retry.")
        }
        guard stored.team.identifier == teamID, stored.team.type == .free else {
            throw ProofIssue.message("The stored Apple session is for a different signing team.")
        }
        var session = stored.auth.session
        session.anisetteData = try await freshAnisette()
        return (stored.team, session)
    }

    private func freshAnisette() async throws -> AnisetteData {
        let saved = try SignerKeychain.read(Self.deviceStateKey)
        let device = try AppleAuth.Device(
            initialState: saved, platform: .mac,
            macOSVersion: "26.6", macOSBuild: "25F84",
            clientInfo: "<MacBookPro18,3> <Mac OS X;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        )
        let headers = try await device.headers()
        let normalized = AnisetteRequestHeaders(rawHeaders: headers).with {
            if $0.serialNumber == nil { $0.serialNumber = AnisetteConstants.defaultSerialNumber }
        }
        let anisette = try AnisetteDataManager.validateAndCreateAnisetteData(from: normalized)
        if saved == nil {
            let state = try await device.serializeState()
            try SignerKeychain.write(state, account: Self.deviceStateKey)
        }
        return anisette
    }

    private func currentKey(team: Team, session: Session) async throws -> KeyStore {
        if let saved = try SignerKeychain.read("development-key") {
            let key = try KeyStore(p12Data: saved)
            guard key.certificate.expiryDate > Date() else {
                throw ProofIssue.message("The saved development certificate expired. Import another certificate for the original Personal Team.")
            }
            return key
        }
        let issued = try await portal.addCertificate(
            machineName: "Personal Signer", type: .iosDevelopment, to: team, session: session
        )
        try saveKey(issued)
        return issued
    }

    private func saveKey(_ key: KeyStore) throws {
        try SignerKeychain.write(key.exportP12(), account: "development-key")
    }
}
