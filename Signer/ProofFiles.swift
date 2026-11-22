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

struct AppBuildNumber: Codable, Comparable, CustomStringConvertible {
    let value: String
    private let components: [Int]

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), value.utf8.count <= 30,
              value.utf8.allSatisfy({ $0 == 46 || (48...57).contains($0) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        self.value = value
        self.components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    var description: String { value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? (try? container.decode(Int.self)).map(String.init)
        guard let raw, let value = Self(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid bundle build number")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.components == rhs.components }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct ImportedApp: Equatable, Identifiable {
    static let probeBundleID = "dev.kellen.personalsigner.storageprobe"

    let name: String
    let bundleID: String
    let build: AppBuildNumber

    var id: String { bundleID }

    static func supportsBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 255 && parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
            && value.utf8.allSatisfy { $0 == 45 || $0 == 46 || (48...57).contains($0)
                || (65...90).contains($0) || (97...122).contains($0) }
    }
}

struct InstallReceipt: Codable, Equatable {
    let identity: AppIdentity
    let build: AppBuildNumber
    let profileID: UUID
    let expiresAt: Date
    let confirmedAt: Date
}

struct PendingInstall: Codable, Equatable {
    let stamp: UUID
    let isSigner: Bool
    let identity: AppIdentity
    let build: AppBuildNumber
    let profileID: UUID
    let expiresAt: Date
    let previousExpiration: Date?
    var sourceBundleID: String?

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
    var apps: [String: InstallReceipt]?

    func receipt(for bundleID: String) -> InstallReceipt? {
        apps?[bundleID] ?? (bundleID == ImportedApp.probeBundleID ? probe : nil)
    }

    mutating func record(_ receipt: InstallReceipt, for bundleID: String) {
        var records = apps ?? [:]
        records[bundleID] = receipt
        apps = records
        if bundleID == ImportedApp.probeBundleID { probe = nil }
    }
    var signer: InstallReceipt?
    var pending: PendingInstall?
    var pendingApps: [String: PendingInstall]?

    func pendingInstall(for bundleID: String) -> PendingInstall? {
        if let job = pendingApps?[bundleID] { return job }
        guard let pending, !pending.isSigner,
              (pending.sourceBundleID ?? ImportedApp.probeBundleID) == bundleID else { return nil }
        return pending
    }

    mutating func setPending(_ install: PendingInstall?, for bundleID: String) {
        var jobs = pendingApps ?? [:]
        jobs[bundleID] = install
        pendingApps = jobs
        if let pending, !pending.isSigner,
           (pending.sourceBundleID ?? ImportedApp.probeBundleID) == bundleID {
            self.pending = nil
        }
    }
}

struct ProofFiles {
    static let profileName = "embedded.mobileprovision"
    static let stampName = "PersonalSignerInstallStamp.txt"
    static let maxIPABytes = 256 * 1024 * 1024

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
    private var importsDirectory: URL { root.appendingPathComponent("Imports", isDirectory: true) }

    func ipaURL(for bundleID: String) -> URL {
        importsDirectory.appendingPathComponent(bundleID + ".ipa")
    }

    func importedApps() throws -> [ImportedApp] {
        try Self.makeDirectory(importsDirectory)
        let legacy = root.appendingPathComponent("StorageProbe.ipa")
        let probe = ipaURL(for: ImportedApp.probeBundleID)
        let fm = FileManager.default
        if fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: probe.path) {
            try fm.moveItem(at: legacy, to: probe)
        }
        return try fm.contentsOfDirectory(at: importsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ipa" }
            .compactMap { try? inspectIPA(at: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

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

    func importIPA(from url: URL, signerBundleID: String) throws -> ImportedApp {
        guard url.pathExtension.lowercased() == "ipa" else {
            throw ProofIssue.message("Choose an .ipa file from Files.")
        }
        let stage = try newStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stage) }
        let candidate = stage.appendingPathComponent("import.ipa")
        try Self.copyIPA(from: url, to: candidate)
        let app = try inspectIPA(at: candidate)
        guard app.bundleID.caseInsensitiveCompare(signerBundleID) != .orderedSame,
              app.bundleID.caseInsensitiveCompare("dev.kellen.personalsigner.proof") != .orderedSame else {
            throw ProofIssue.message("Use Refresh All to refresh Personal Signer itself.")
        }
        try Self.makeDirectory(importsDirectory)
        let fm = FileManager.default
        let destination = ipaURL(for: app.bundleID)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: candidate)
        } else {
            try fm.moveItem(at: candidate, to: destination)
        }
        return app
    }

    private static func copyIPA(from source: URL, to destination: URL) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, (1...maxIPABytes).contains(size) else {
            throw ProofIssue.message("Choose a local IPA up to 256 MB. Download it in Files first if needed.")
        }
        try write(Data(), to: destination)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var total = 0
        while let block = try input.read(upToCount: 1024 * 1024), !block.isEmpty {
            total += block.count
            guard total <= maxIPABytes else { throw ProofIssue.message("The IPA exceeds 256 MB.") }
            try output.write(contentsOf: block)
        }
        guard total == size else { throw ProofIssue.message("The IPA changed while being copied. Import it again.") }
        try output.synchronize()
    }

    func inspectIPA(at ipa: URL, extractTo destination: URL? = nil) throws -> ImportedApp {
        let reader = try SideSign.Archive.Reader.open(at: ipa)
        let entries = try reader.entries()
        guard !entries.isEmpty, entries.count <= 16_384 else {
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
            guard entry.uncompressedSize >= 0, entry.uncompressedSize <= 192 * 1024 * 1024 else {
                throw ProofIssue.message("The IPA contains an oversized entry.")
            }
            total += entry.uncompressedSize
            guard total <= 768 * 1024 * 1024 else {
                throw ProofIssue.message("The unpacked IPA exceeds 768 MB.")
            }
            let parts = name.split(separator: "/")
            if let root = parts.first, ["SwiftSupport", "Symbols", "iTunesMetadata.plist", "iTunesArtwork", "iTunesArtwork@2x"].contains(root) {
                continue
            }
            guard parts.first == "Payload" else {
                throw ProofIssue.message("Use an IPA with a single app under Payload.")
            }
            if parts.count == 1 && entry.isDirectory { continue }
            guard parts.count >= 2, parts[1].hasSuffix(".app"),
                  !parts.dropFirst(2).contains(where: {
                      $0.lowercased().hasSuffix(".appex") || $0.lowercased().hasSuffix(".app")
                  }) else {
                throw ProofIssue.message("This build supports one app bundle. Export it without app extensions or nested apps.")
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
        var metadata: ImportedApp?
        try reader.goToFirstFile()
        repeat {
            let entry = try reader.currentEntry()
            let name = try Self.safeName(entry)
            if name == appRoot + "/Info.plist" {
                guard !entry.isDirectory, entry.uncompressedSize <= 256 * 1024 else {
                    throw ProofIssue.message("The app's Info.plist is invalid.")
                }
                let plist = try reader.readCurrentFile()
                metadata = try Self.readAppInfo(plist)
            }
            if let destination, name == appRoot || name.hasPrefix(appRoot + "/") {
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

    func setBundleID(_ bundleID: String, for app: URL) throws {
        let url = app.appendingPathComponent("Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        guard var dictionary = info as? [String: Any] else {
            throw ProofIssue.message("The app’s Info.plist is invalid.")
        }
        dictionary["CFBundleIdentifier"] = bundleID
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        try Self.write(data, to: url)
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

    private static func readAppInfo(_ data: Data) throws -> ImportedApp {
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String,
              ImportedApp.supportsBundleID(bundleID),
              let rawBuild = info["CFBundleVersion"] as? String,
              let build = AppBuildNumber(rawBuild),
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              !executable.contains("/"), !executable.contains("\\"),
              executable != ".", executable != ".." else {
            throw ProofIssue.message("The IPA must have a valid iOS bundle identifier, executable and numeric build version.")
        }
        if let platforms = info["CFBundleSupportedPlatforms"] as? [String], !platforms.contains("iPhoneOS") {
            throw ProofIssue.message("Export a device IPA built for iPhoneOS.")
        }
        let label = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleID
        let name = String(label.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
        return ImportedApp(name: name.isEmpty ? bundleID : name, bundleID: bundleID, build: build)
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
