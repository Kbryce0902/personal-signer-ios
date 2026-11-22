# Personal Signer

Native SwiftUI proof project for an iPhone 18 Pro Max on iOS 27.2.1. It implements the candidate on-device sign, install and self-refresh workflow for the supplied Storage Probe app. The arm64 IPAs passed build and archive verification under Xcode 27.2. Pairing, installation and refresh still need a real-device trial. [Verified GitHub Actions build](https://github.com/Kbryce0902/personal-signer-ios/actions/runs/45048110063)

The signer uses Apple Personal Team provisioning and an iPhone-approved Remote Pairing record. The App Store build of LocalDevVPN supplies the local tunnel. Embedding a Packet Tunnel Provider requires the `com.apple.developer.networking.networkextension` entitlement with the `packet-tunnel-provider` value. The free-signed signer relies on the companion for that capability. Apple sign-in uses on-device metadata generation and two user-supplied Apple Music ARM64 libraries. The app has no remote signing or anisette endpoint. [Apple Network Extensions entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension) · [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) · [AnisetteKit](https://github.com/mahee96/AnisetteKit/tree/db8b41022697b6c19be8a5f01a1ce834145a2a26)

## Build the unsigned IPAs

Use a Mac with Xcode 27.2, the iPhoneOS SDK, Git and Python 3. The build script checks out minimuxer at its pinned revision as a local package because its manifest uses relative package paths. Xcode fetches the remaining pinned Swift packages and checksum-pinned frameworks. [Xcode 27.2 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes)

```bash
bash scripts/build-ipas.sh
```

The script builds arm64 device bundles with signing turned off, verifies the iPhoneOS Mach-O executables and bundle metadata, and writes these files under `build/ipas`. The **Build unsigned iOS IPAs** GitHub Actions workflow runs the same script on the `xcode-27` runner and supplies the files as an artifact.

| File | Purpose |
| --- | --- |
| `PersonalSigner-proof-unsigned.ipa` | Windows USB first install and recovery |
| `StorageProbe-build-1-unsigned.ipa` | First phone-only install and repeat refresh |
| `StorageProbe-build-2-unsigned.ipa` | In-place update with the same app identity |
| `SHA256SUMS` | Verify the IPAs after copying them |

The unsigned signer bundle ID is `dev.kellen.personalsigner.proof`. The USB installer can append the team ID. The running signer reads and retains the exact provisioned bundle ID, team and application identifier. Storage Probe uses `dev.kellen.personalsigner.storageprobe` across both builds.

Follow [WINDOWS-SETUP.md](WINDOWS-SETUP.md) for first install, pairing and recovery. Complete the device tests in [HANDOFF.md](HANDOFF.md) before use with AetherMedia.

Apple Personal Teams support three active development apps per device and seven-day profiles. The signer and Storage Probe use one slot each. Use the actual Apple profile expiry shown in the app. An install can return the same expiry when Apple reuses a profile. [Apple Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account/)

## Source and licenses

The original project code is available under AGPL-3.0-only. The linked source revisions are in `Package.resolved`. If distributing binaries, include complete corresponding source, build inputs and notices for the linked software. Consult the pinned license texts and framework build recipes.

| Component | Role | Source |
| --- | --- | --- |
| SideSign | Apple developer portal, profiles, signing and ZIP handling | [Pinned GPL-3.0 source](https://github.com/SideStore/SideSign/tree/752d1ef602aa792a432ffa1e71646dc1ecf7363c) |
| AnisetteKit | Local Apple authentication metadata | [Pinned AGPL-3.0 source](https://github.com/mahee96/AnisetteKit/tree/db8b41022697b6c19be8a5f01a1ce834145a2a26) |
| minimuxer | Trusted pairing and developer installation | [Pinned AGPL-3.0 source](https://github.com/SideStore/minimuxer/tree/12be70dc2627307a16bfd2dc7a009080d5bec909) |
| iLoader | Separate Windows USB bootstrap and recovery tool | [v2.4.2 MIT source](https://github.com/nab138/iloader/tree/v2.4.2) |
| LocalDevVPN | Separate App Store-signed local tunnel | [App Store listing](https://apps.apple.com/us/app/localdevvpn/id6755608044) |

Obtain the Apple authentication libraries separately for personal use under Apple's licensing. This project is for development sideloading.
