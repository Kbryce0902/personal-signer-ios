import Foundation
import Security
import SideSign

enum ProofIssue: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

struct AppIdentity: Codable, Equatable {
    let bundleID: String
    let teamID: String
    let applicationID: String

    init(profile: ProvisioningProfile) throws {
        guard let applicationID = profile.entitlements["application-identifier"] as? String,
              !applicationID.contains("*"),
              applicationID.hasSuffix("." + profile.bundleIdentifier),
              !profile.teamIdentifier.isEmpty else {
            throw ProofIssue.message("The development profile has no exact app identity.")
        }
        self.bundleID = profile.bundleIdentifier
        self.teamID = profile.teamIdentifier
        self.applicationID = applicationID
    }
}

struct ProbeBuild: Codable, Equatable {
    static let bundleID = "dev.kellen.personalsigner.storageprobe"

    let name: String
    let bundleID: String
    let build: Int
}

struct InstallReceipt: Codable, Equatable {
    let identity: AppIdentity
    let build: Int
    let profileID: UUID
    let expiresAt: Date
    let confirmedAt: Date
}

struct PendingInstall: Codable, Equatable {
    let stamp: UUID
    let isSigner: Bool
    let identity: AppIdentity
    let build: Int
    let profileID: UUID
    let expiresAt: Date
    let previousExpiration: Date?

    func receipt(at date: Date = Date()) -> InstallReceipt {
        InstallReceipt(
            identity: identity, build: build, profileID: profileID,
            expiresAt: expiresAt, confirmedAt: date
        )
    }
}

struct ProofState: Codable {
    var deviceUDID: String?
    var probe: InstallReceipt?
    var signer: InstallReceipt?
    var pending: PendingInstall?
}

struct ProofFiles {
    static let profileName = "embedded.mobileprovision"
    static let stampName = "PersonalSignerInstallStamp.txt"
    static let adiNames = ["libCoreADI.so", "libstoreservicescore.so"]
    static let maxIPABytes = 64 * 1024 * 1024

    let root: URL

    init() throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        var root = base.appendingPathComponent("PersonalSigner", isDirectory: true)
        try Self.makeDirectory(root)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        self.root = root
    }

    var stateURL: URL { root.appendingPathComponent("state.json") }
    var pairingURL: URL { root.appendingPathComponent("pairing.plist") }
    var ipaURL: URL { root.appendingPathComponent("StorageProbe.ipa") }
    var adiDirectory: URL { root.appendingPathComponent("AppleADI", isDirectory: true) }

    func readState() throws -> ProofState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return ProofState()
        }
        return try JSONDecoder().decode(ProofState.self, from: Data(contentsOf: stateURL))
    }

    func save(_ state: ProofState) throws {
        try Self.write(JSONEncoder().encode(state), to: stateURL)
    }

    func newStagingDirectory() throws -> URL {
        let location = root.appendingPathComponent("Staging", isDirectory: true)
        try Self.makeDirectory(location)
        let job = location.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.makeDirectory(job)
        return job
    }

    func cleanStagingOnLaunch() throws {
        let location = root.appendingPathComponent("Staging", isDirectory: true)
        if FileManager.default.fileExists(atPath: location.path) {
            try FileManager.default.removeItem(at: location)
        }
    }

    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700]
        )
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func readImport(_ url: URL, maxBytes: Int) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= maxBytes else {
            throw ProofIssue.message("Choose a regular file within the proof build's size limit.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: maxBytes + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= maxBytes else {
            throw ProofIssue.message("The selected file is empty or too large.")
        }
        return bytes
    }

    func importProbe(from url: URL) throws -> ProbeBuild {
        let stage = try newStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stage) }
        let data = try Self.readImport(url, maxBytes: Self.maxIPABytes)
        let candidate = stage.appendingPathComponent("import.ipa")
        try Self.write(data, to: candidate)
        let build = try inspectProbe(at: candidate)
        try Self.write(data, to: ipaURL)
        return build
    }

    func inspectProbe(at ipa: URL, extractTo destination: URL? = nil) throws -> ProbeBuild {
        let reader = try SideSign.Archive.Reader.open(at: ipa)
        let entries = try reader.entries()
        guard !entries.isEmpty, entries.count <= 4_096 else {
            throw ProofIssue.message("The IPA has an unsupported number of entries.")
        }

        var appRoot: String?
        var names = Set<String>()
        var total: Int64 = 0
        for entry in entries {
            let name = try Self.safeName(entry)
            guard names.insert(name.lowercased()).inserted else {
                throw ProofIssue.message("The IPA contains duplicate paths.")
            }
            guard entry.uncompressedSize >= 0, entry.uncompressedSize <= 128 * 1024 * 1024 else {
                throw ProofIssue.message("The IPA contains an oversized entry.")
            }
            total += entry.uncompressedSize
            guard total <= 256 * 1024 * 1024 else {
                throw ProofIssue.message("The unpacked IPA exceeds the proof build's size limit.")
            }
            let parts = name.split(separator: "/")
            guard parts.first == "Payload" else {
                throw ProofIssue.message("Use a proof IPA with a single app under Payload.")
            }
            if parts.count == 1 && entry.isDirectory { continue }
            guard parts.count >= 2, parts[1].hasSuffix(".app"),
                  !parts.dropFirst(2).contains(where: {
                      $0.hasSuffix(".appex") || $0.hasSuffix(".app")
                  }) else {
                throw ProofIssue.message("Use the Storage Probe IPA without app extensions or nested apps.")
            }
            let root = parts.prefix(2).joined(separator: "/")
            guard appRoot == nil || appRoot == root else {
                throw ProofIssue.message("The IPA contains multiple app bundles.")
            }
            appRoot = root
        }

        guard let appRoot, names.contains((appRoot + "/Info.plist").lowercased()) else {
            throw ProofIssue.message("The IPA is missing the app's Info.plist.")
        }
        var metadata: ProbeBuild?
        try reader.goToFirstFile()
        repeat {
            let entry = try reader.currentEntry()
            let name = try Self.safeName(entry)
            if name == appRoot + "/Info.plist" {
                guard !entry.isDirectory, entry.uncompressedSize <= 256 * 1024 else {
                    throw ProofIssue.message("The app's Info.plist is invalid.")
                }
                let plist = try reader.readCurrentFile()
                metadata = try Self.readProbeInfo(plist)
            }
            if let destination {
                let target = destination.appendingPathComponent(name, isDirectory: entry.isDirectory)
                if entry.isDirectory {
                    try Self.makeDirectory(target)
                } else {
                    try Self.makeDirectory(target.deletingLastPathComponent())
                    try reader.extractCurrentFile(to: target)
                    try FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.complete],
                        ofItemAtPath: target.path
                    )
                }
            }
        } while reader.goToNextFile()

        guard let metadata else {
            throw ProofIssue.message("The IPA is missing the app's Info.plist.")
        }
        return metadata
    }

    func importADI(from url: URL) throws {
        let stage = try newStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stage) }
        let archive = stage.appendingPathComponent("AppleADI.zip")
        try Self.write(Self.readImport(url, maxBytes: 32 * 1024 * 1024), to: archive)
        let reader = try SideSign.Archive.Reader.open(at: archive)
        let entries = try reader.entries()
        let actualNames = try entries.map { try Self.safeName($0) }
        guard actualNames.sorted() == Self.adiNames.sorted() else {
            throw ProofIssue.message("Choose AppleADI.zip created by the setup script.")
        }

        let payload = stage.appendingPathComponent("ValidatedADI", isDirectory: true)
        try Self.makeDirectory(payload)
        try reader.goToFirstFile()
        repeat {
            let entry = try reader.currentEntry()
            guard !entry.isDirectory, entry.uncompressedSize >= 64,
                  entry.uncompressedSize <= 16 * 1024 * 1024 else {
                throw ProofIssue.message("An Apple authentication library has an invalid size.")
            }
            let content = try reader.readCurrentFile()
            let header = Array(content.prefix(20))
            guard header.count == 20,
                  Array(header.prefix(6)) == [127, 69, 76, 70, 2, 1],
                  Array(header[16..<20]) == [3, 0, 183, 0] else {
                throw ProofIssue.message("The authentication libraries must be Apple Music's ARM64 ELF files.")
            }
            try Self.write(content, to: payload.appendingPathComponent(entry.filename))
        } while reader.goToNextFile()

        let fm = FileManager.default
        if fm.fileExists(atPath: adiDirectory.path) {
            _ = try fm.replaceItemAt(adiDirectory, withItemAt: payload)
        } else {
            try fm.moveItem(at: payload, to: adiDirectory)
        }
    }

    private static func safeName(_ entry: SideSign.Archive.Entry) throws -> String {
        let raw = entry.filename
        let name = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        let fileType = (entry.externalAttributes >> 16) & 0o170000
        guard !name.isEmpty, !name.contains("\\"), !name.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              fileType == 0 || fileType == 0o040000 || fileType == 0o100000 else {
            throw ProofIssue.message("The archive contains an unsafe path or file type.")
        }
        return name
    }

    private static func readProbeInfo(_ data: Data) throws -> ProbeBuild {
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String,
              bundleID == ProbeBuild.bundleID,
              let rawBuild = info["CFBundleVersion"] as? String,
              let build = Int(rawBuild), build > 0 else {
            throw ProofIssue.message("This proof build accepts only the Storage Probe IPA.")
        }
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "Storage Probe"
        return ProbeBuild(name: name, bundleID: bundleID, build: build)
    }
}

enum SignerKeychain {
    private static let service = "dev.kellen.personalsigner.secrets"

    static func read(_ account: String) throws -> Data? {
        var query = identity(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw ProofIssue.message("Unlock this iPhone and try again. The signing Keychain could not be read.")
        }
        return data
    }

    static func write(_ value: Data, account: String) throws {
        let query = identity(account)
        let changes = [kSecValueData as String: value]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ProofIssue.message("The signing Keychain could not securely save the new state.")
        }
    }

    private static func identity(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}
