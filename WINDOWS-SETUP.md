# Windows 10 first install and recovery

## USB bootstrap

1. Copy the three device IPAs from the Mac build to Windows. Keep the original unsigned Personal Signer IPA for recovery.
2. Install Apple's Windows device support. Confirm that Apple Devices or iTunes sees the unlocked iPhone over a USB data cable. Accept **Trust This Computer** and enter the passcode on the iPhone. For a read-only preflight, run `.\scripts\windows-usb-preflight.ps1` in PowerShell from the source folder. [Apple USB troubleshooting](https://support.apple.com/en-us/108643) · [Trust This Computer](https://support.apple.com/en-us/109054)
3. Install [iLoader v2.4.2](https://github.com/nab138/iloader/releases/tag/v2.4.2). Select the iPhone and choose **Import IPA** with `PersonalSigner-proof-unsigned.ipa`. Use your own free Apple Account and complete Apple's two-factor prompt. iLoader signs on Windows and can use a custom authentication metadata provider. Record the signed bundle ID shown by the signer after first launch.
4. On the iPhone, enable **Settings → Privacy & Security → Developer Mode** if needed. Restart and confirm the device prompt. Under **Settings → General → VPN & Device Management**, trust the developer account if prompted and allow the requested restart. Open Personal Signer. [Apple Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
5. While the iPhone is attached and unlocked, choose **Manage Pairing File → Export** in iLoader and follow the trusted pairing prompts. The export must include Remote Pairing. Transfer it using a private local path to Files, such as your authenticated LAN share, and choose **Import Pairing Record** in Personal Signer. Remove the temporary copy after import.
6. Install [LocalDevVPN from the App Store](https://apps.apple.com/us/app/localdevvpn/id6755608044). Connect it with Wi-Fi on and grant its standard VPN prompt. In Personal Signer, use the peer configured in LocalDevVPN, allow Local Network access, and tap **Check Connection**. If needed, tap **Find Remote Pairing Ports**, select the advertised port and retry. The app checks that the live device is authorized by its USB-installed profile.

For a USB bootstrap with local authentication metadata, [Sideloadly has a Local Anisette option](https://sideloadly.io/faq). Select it in Advanced Options, use your own account, and check the final bundle ID. You can still use iLoader to export the pairing record. Use the same USB signing tool, bundle ID options and Apple Account for recovery.

## Local Apple sign-in

1. With Wi-Fi connected and LocalDevVPN off, tap **Check Apple Setup**. Personal Signer build 5 and later include the local authentication provider, so this step works without importing a ZIP or entering your account.
2. Once the check succeeds, tap **Sign In** and use the same free Apple Account that signed the app over USB. Complete Apple's verification on the phone. The app stores its session, development private key and persistent authentication state in the device-only Keychain.
3. Import Storage Probe build 1. Unplug the iPhone and turn the PC off before tapping **Sign and Install** in the Storage Probe row. Keep the phone unlocked on Wi-Fi with LocalDevVPN connected.
4. After the Probe confirms data survives an in-place update, import an unsigned IPA from your project with **Import IPA**. If Apple reports its development certificate limit, use **Import My Development Certificate** with your own valid PKCS#12 export for the same Personal Team. Keep any existing certificate active if other apps still depend on it.

## USB recovery after expiration

1. Leave the expired signer installed. Reconnect and unlock the iPhone over USB. Check trust and Developer Mode.
2. Use the same desktop signing tool, Apple Account, team and bundle ID settings to install the original signer IPA over the existing app. With iLoader, use the original unsuffixed IPA so iLoader applies the same team suffix. Cancel and correct the account or bundle ID if the resulting identity would change.
3. Open the renewed signer. Confirm the same bundle ID, a current expiration and retained settings. If pairing fails, export and import a new Remote Pairing record, reconnect LocalDevVPN and check the current port. Sign in again if Apple has expired the session.

If a compatible in-place install is denied, record the desktop installer's error before taking an action that could remove the app's container.
