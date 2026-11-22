import AnisetteKit
import Foundation
import SideSign

@MainActor
final class AppleSigning {
    private struct ADIState: Codable {
        var identifier = UUID()
        var blob: Data?
    }

    private struct StoredSession: Codable {
        let auth: AuthSession
        let team: Team
    }

    private let files: ProofFiles
    private let portal = DeveloperPortal()
    private var adiClient: AnisetteClient?

    init(files: ProofFiles) {
        self.files = files
        SideSignLogging.setLogging(false)
        AnisetteKitLogging.setLogging(false)
    }

    var hasLocalADI: Bool {
        AnisetteClient.validateLibrariesExist(at: files.adiDirectory)
    }

    func invalidateADIClient() {
        adiClient = nil
    }

    func isSignedIn(teamID: String) throws -> Bool {
        guard let bytes = try SignerKeychain.read("apple-session") else { return false }
        let current = try JSONDecoder().decode(StoredSession.self, from: bytes)
        return current.team.identifier == teamID && current.auth.session.isValid
    }

    func signIn(
        appleID: String, password: String, teamID: String,
        verification: @escaping DeveloperPortal.VerificationHandler
    ) async throws {
        let anisette = try await freshAnisette()
        let auth = try await portal.authenticate(
            appleID: appleID, password: password,
            anisetteData: anisette, xcodeVersion: "27.2",
            machinePassword: nil, accountRepairHandler: { _, _ in .cancel },
            verificationHandler: verification
        )
        let teams = try await portal.fetchTeams(for: auth.account, session: auth.session)
        guard let team = teams.first(where: { $0.identifier == teamID && $0.type == .free }) else {
            throw ProofIssue.message("Sign in with the free Apple Account that installed this signer over USB. The signing team doesn't match.")
        }
        let bytes = try JSONEncoder().encode(StoredSession(auth: auth, team: team))
        try SignerKeychain.write(bytes, account: "apple-session")
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
        guard let data = try SignerKeychain.read("apple-session") else {
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
        guard hasLocalADI else {
            throw ProofIssue.message("Import AppleADI.zip before signing in.")
        }
        let client: AnisetteClient
        if let adiClient {
            client = adiClient
        } else {
            let libraryDirectory = files.adiDirectory
            let provisioning = files.root.appendingPathComponent("AppleAuth", isDirectory: true)
            try ProofFiles.makeDirectory(provisioning)
            client = try AnisetteClient(
                provisioningDir: provisioning,
                libraryDirectoryResolver: { libraryDirectory }
            )
            adiClient = client
        }
        var state = ADIState()
        if let bytes = try SignerKeychain.read("adi-state") {
            state = try JSONDecoder().decode(ADIState.self, from: bytes)
        }
        let result = try await client.getAnisetteData(
            identifier: state.identifier, storage: .memory(existingBlob: state.blob)
        )
        if let blob = result.newBlob {
            state.blob = blob
            try SignerKeychain.write(JSONEncoder().encode(state), account: "adi-state")
        }
        return try AnisetteDataManager.validateAndCreateAnisetteData(from: result.headers)
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
