# Personal Signer handoff

Updated November 22, 2026. Target hardware is an iPhone 18 Pro Max running iOS 27.2.1.

## Status

The workspace started empty. It now contains the SwiftUI signer proof, a local-value test app, pinned package resolution, macOS IPA packaging, and Windows setup and recovery instructions.

The local workspace is x86_64 Linux with no Xcode, Apple SDK or USB iPhone access. The initial Windows USB preflight timed out. GitHub Actions compiled and packaged the signer and both Storage Probe builds on a macOS runner. The user confirmed that the signer installed through iLoader and opened on the iPhone. The user also reported a trusted connection in PersonalSigner. On-device Apple provisioning, installation of Storage Probe and PC-off refresh still need hardware results.

## Decisions

- SideSign `752d1ef602aa792a432ffa1e71646dc1ecf7363c` supplies Apple authentication, provisioning and signing. AnisetteKit `db8b41022697b6c19be8a5f01a1ce834145a2a26` generates the authentication metadata locally. The user supplies the two Apple ARM64 ADI libraries separately.
- minimuxer `12be70dc2627307a16bfd2dc7a009080d5bec909` connects to the trusted Remote Pairing service and Apple installation proxy. The App Store build of LocalDevVPN supplies the tunnel. Embedding an iOS Packet Tunnel Provider would require `com.apple.developer.networking.networkextension` with `packet-tunnel-provider`. The Personal Team signer uses Local Network permission and the companion's tunnel.
- The proof checks the device, certificate, signing team and application identifier in the Apple profile before sending a bundle. It preserves the original signed app identity. The app never removes an installed app or revokes a signing certificate automatically.
- Probe receipts depend on terminal completion from the paired installation proxy. Before submitting self-refresh, the signer records the expected profile UUID, expiry, build, signed resource stamp and app identity. The next launch checks them against the running copy before recording success. A failed or interrupted install leaves the previous receipt available.
- The private key, Apple session and ADI state go in the device-only Keychain. Pairing records, the IPA, receipts and staging files use protected application support excluded from backup. The app disables signing and pairing library logs.
- This proof has one managed target. Multi-app management, 48-hour and 24-hour notifications and best-effort background scheduling depend on passing the hardware tests. Keep the first proof in the foreground with the phone unlocked. iOS 27.2 has an upstream lock-related Remote Pairing failure report. [Upstream report](https://github.com/SideStore/SideStore/issues/1723)

## Exact build command

```bash
bash scripts/build-ipas.sh
```

Use Xcode 27.2, the iPhoneOS SDK, Git and Python 3. The script fetches the pinned minimuxer checkout as a local Swift package so its relative dependency paths resolve. It builds `PersonalSigner` at build 3 and `StorageProbe` at builds 1 and 2. It uses `-configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -onlyUsePackageVersionsFromResolvedFile` with `ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`. The unsigned IPAs go under `build/ipas`.

The Actions workflow uses the standard `xcode-27` runner and selects Xcode 27.2. It signs in to neither Apple nor the test iPhone. Use the provenance recorded below to identify the exact source and runner for a test build.

## GitHub build status

GitHub Actions [run 45048110063](https://github.com/Kbryce0902/personal-signer-ios/actions/runs/45048110063) succeeded using Xcode 27.2 build `27B52` on source commit `95f1e8f5be00c62a380123a47cc1e1564c53bca8`. The job's `PersonalSigner-unsigned-ipas` artifact contains the signer IPA, both Storage Probe IPAs and `SHA256SUMS`. The archive digest matched on download. The three IPAs also passed the local arm64 iPhoneOS, unsigned bundle metadata and SHA-256 checks.

GitHub Actions [run 45052192852](https://github.com/Kbryce0902/personal-signer-ios/actions/runs/45052192852) built and verified signer build 2 on source commit `007f781191b86feb906686d90b8241a956dbde30`. Its IPA SHA-256 is `d2ad8d21d630f1ccf9eb55aece24b06c61626ec782a36569e14a8a38134d12ff`. Install it over build 1 using the original iLoader account and bundle ID settings. Retry Apple sign-in and capture the displayed stage and code.

Build 1 failed at on-device sign-in with a generic message. Build 2 reports whether local Apple authentication, Apple Account sign-in, or Personal Team lookup failed. It displays numeric error codes when available and keeps Apple response contents off the screen. On iPhone, build 2 reported `Local Apple authentication failed` with ADI `-45063` before Apple Account sign-in.

GitHub Actions [run 45053651755](https://github.com/Kbryce0902/personal-signer-ios/actions/runs/45053651755) built signer build 3 from `be1cba97f5f76b8b4a0947e14335ceee0f02bdb1` with Xcode 27.2. The downloaded IPA passed the arm64 iPhoneOS, unsigned bundle and SHA-256 checks. Signer SHA-256 is `468f0690f602f01818571ccac7aa6f3c9a7aa31262131e3547942080b10f977c`. Install over build 2 using the original iLoader identity and retry sign-in on the iPhone.

## ADI retry recovery

`-45063` is the pending local ADI session code. In the pinned AnisetteKit source, the Unicorn provider keeps its VM alive for the process and starts a native session before the request to Apple that finishes provisioning. The high-level client does not cancel that session if the next step fails. [ADI error mapping](https://github.com/Dadoum/Provision/blob/main/lib/provision/adi.d) · [Pinned AnisetteKit source](https://github.com/mahee96/AnisetteKit/tree/db8b41022697b6c19be8a5f01a1ce834145a2a26)

Build 3 wraps the upstream provider and calls its native cancel function on a failed attempt with a tracked session. It displays fixed messages for start, finish and local authentication-data generation failures. An untracked pending session requires a fresh process. Fully close Personal Signer from the iOS app switcher, reopen it and try sign-in once. Keep existing pairing, bundle identity and Keychain entries. Keep LocalDevVPN off during this sign-in check. The first error on a fresh process is the evidence needed if sign-in still fails.

## Workspace checks

| Check | Result |
| --- | --- |
| OpenStep project file, shared schemes, source membership, privacy plist and 10 Swift package pins | Passed static check |
| ADI preparation with single and split synthetic APKs, missing and invalid files, conflicting libraries, and existing output | Passed |
| Bash script syntax and build environment preflight | Passed. Running the script stopped at the macOS/Xcode prerequisite with exit code 2 |
| Windows PowerShell preflight | Source reviewed. Remote Windows call timed out, and PowerShell is unavailable in the workspace |
| IPA verification | Passed synthetic arm64 device, simulator, embedded-profile and wrong-identity fixtures |
| Swift compilation and IPA packaging | Passed on Xcode 27.2 for the signer and both Storage Probe builds |
| Downloaded IPA verification | All three SHA-256 digests matched. Executables target arm64 iPhoneOS and the bundles contain no provisioning profiles |

## Hardware acceptance matrix

Record the iOS build, signer build, terminal result and profile expiration before and after each run. Use the visible short stamp to distinguish installed copies.

| Scenario | Acceptance evidence | Result |
| --- | --- | --- |
| USB bootstrap | Install the unsigned signer over USB using iLoader and open it on the iPhone. | User confirmed install and launch |
| Trusted Remote Pairing | Import the USB Remote Pairing record. With USB unplugged, **Check Connection** receives a live response from this iPhone. | User reported trusted connection |
| Apple authentication and provisioning | With the PC off, Apple sign-in and 2FA succeed with local ADI. Apple issues a development certificate and profile for the correct team and iPhone. | Build 2 reported ADI `-45063`. Awaiting a build 3 retry |
| First install | With the PC unplugged and off, import build 1. Storage Probe opens with build 1 and a new install stamp. Save a value such as `probe-431`. | Pending |
| Repeat refresh | Refresh build 1. The install stamp changes and the saved value remains. Repeat when Apple issues a later expiry and record the new date. | Pending |
| In-place upgrade | Import and install build 2 with build 1 still present. Confirm build 2, a new install stamp and the original saved value. | Pending |
| Self-refresh | Choose **Refresh Probe, Then Signer**. Confirm the probe finishes before the signer updates. Reopen the signer and check the receipt, same identity, retained Keychain session and later expiry. A reinstall with the same expiry is partial evidence. | Pending |
| Reboot with PC off | Reboot the iPhone, unlock, reconnect LocalDevVPN, and rediscover the port if needed. Refresh Storage Probe again and confirm the saved value. | Pending |
| Interrupted refresh | Disconnect the local tunnel or stop the signer during an install attempt. Check the prior receipt and the pending state. Reconnect and retry in place. | Pending |
| USB recovery | Reinstall the original signer IPA over USB with the same account and bundle identity. Rehearse in place, then repeat after a real expiry. Check that the signer launches and its stored setup remains. | Pending |
| AetherMedia | After the proof passes, add support for its packaging and entitlements. Verify the existing signed identity before update, then confirm watch history and settings survive. | Pending |

## Next implementation gate

Finish a fresh sign-in attempt on build 3 before advancing to Storage Probe. If it fails, record the first displayed stage and code after launch. Once Apple sign-in and provisioning succeed on the same Personal Team, continue the PC-off hardware matrix before expanding IPA support or building out notifications and the release queue.
