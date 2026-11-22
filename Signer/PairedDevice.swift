import Foundation
import Minimuxer
import SideSign

struct TunnelSettings: Equatable {
    let peer: String
    let remotePairingPort: UInt16

    init(peer: String, port: String) throws {
        let text = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let address = parts.compactMap { UInt8($0) }
        guard parts.count == 4, address.count == 4,
              address.map({ String($0) }).joined(separator: ".") == text,
              let port = UInt16(port), port != 0 else {
            throw ProofIssue.message("Enter LocalDevVPN's private IPv4 peer and a valid Remote Pairing port.")
        }
        guard address[0] == 10 ||
              (address[0] == 172 && (16...31).contains(address[1])) ||
              (address[0] == 192 && address[1] == 168) else {
            throw ProofIssue.message("Use the private peer address shown in LocalDevVPN.")
        }
        self.peer = text
        self.remotePairingPort = port
    }
}

@MainActor
final class PairedDevice {
    private let muxer = Minimuxer.shared
    private var activeSettings: TunnelSettings?
    private var activePairing: String?
    private let files: ProofFiles

    init(files: ProofFiles) {
        self.files = files
        muxer.core.setLogging(false)
    }

    var hasPairing: Bool {
        FileManager.default.fileExists(atPath: files.pairingURL.path)
    }

    func importPairing(from url: URL) throws {
        let bytes = try ProofFiles.readImport(url, maxBytes: 256 * 1024)
        guard let parsed = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let identifier = parsed["identifier"] as? String, !identifier.isEmpty,
              let privateKey = parsed["private_key"] as? Data, !privateKey.isEmpty,
              let publicKey = parsed["public_key"] as? Data, !publicKey.isEmpty else {
            throw ProofIssue.message("Export this iPhone's Remote Pairing record from iLoader over USB and import it here.")
        }
        let canonical = try PropertyListSerialization.data(fromPropertyList: parsed, format: .xml, options: 0)
        try ProofFiles.write(canonical, to: files.pairingURL)
    }

    func connect(settings: TunnelSettings, bootstrapProfile: ProvisioningProfile, pinnedUDID: String?) async throws -> String {
        guard hasPairing else {
            throw ProofIssue.message("Import this iPhone's Remote Pairing record first.")
        }
        let content = try String(contentsOf: files.pairingURL, encoding: .utf8)

        do {
            if activeSettings != settings || activePairing != content {
                if activeSettings != nil {
                    try await muxer.core.stop()
                    activeSettings = nil
                    activePairing = nil
                }
                muxer.set(MinimuxerParams(remotePairingPort: settings.remotePairingPort))
                await muxer.core.bindConnectionConfig(ConnectionConfigBinding(
                    setTunnelIfaceIp: { _ in },
                    setTunnelPeerIp: { _ in },
                    setTunnelPeerSubnetMask: { _ in },
                    setTunnelPeerReachable: { _ in },
                    setTunnelIfaceSubnetMask: { _ in },
                    getRemoteServerIp: { "" },
                    setRemoteReachable: { _ in },
                    getOverrideTunnelPeerIp: { settings.peer },
                    setOverrideTunnelPeerReachable: { _ in },
                    getConnectionMode: { .localVPN },
                    resolveServicePort: nil
                ))
                try await muxer.core.start(pairingFile: content, mountPath: files.root.path, preferred: .rppairing)
                activeSettings = settings
                activePairing = content
            }

            try await muxer.core.isReady(withNetworkCheck: true, withDDIMountCheck: false).get()
            let udid = try await muxer.core.fetchUDID()
            guard bootstrapProfile.deviceIDs.contains(where: { AppleSigning.sameUDID($0, udid) }),
                  pinnedUDID.map({ AppleSigning.sameUDID($0, udid) }) ?? true else {
                throw ProofIssue.message("The paired device doesn't match this signer's USB installation.")
            }
            return udid
        } catch {
            try? await muxer.core.stop()
            activeSettings = nil
            activePairing = nil
            throw error
        }
    }

    func stage(_ app: URL, as stagingID: String) async throws {
        try await muxer.core.sendAppBundleAfc(bundleId: stagingID, appURL: app)
    }

    func install(stagingID: String, appName: String) async throws {
        try await muxer.core.installAppBundle(bundleId: stagingID, appName: appName)
    }
}
