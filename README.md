# PassVault

An offline password vault with **native SwiftUI for iOS** and **native Kotlin / Jetpack Compose for Android**. No backend, account, analytics, or cloud sync.

This is a development implementation, **not yet audited or ready to hold valuable credentials**. See [feature status](docs/FEATURES.md), [security model](docs/SECURITY.md), and the [encrypted file specification](docs/FORMAT.md).

## Included

- Password and biometric unlock; encrypted local records; 10-failure local erasure.
- Search, favorites, groups, editable records, hidden secrets, adjustable strong password generation.
- Ordered custom usernames, passwords, notes, and security question-answer pairs.
- Password-authorized CSV/encrypted export, confirmed import, master-password change, and clipboard handling.
- An [app icon](assets/app-icon.png) generated for both platforms. [Prompt and asset details](assets/README.md).

## iOS

Requires full Xcode, an iOS 17+ device, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Command Line Tools alone cannot compile the iOS app or run XCTest.

```sh
cd ios
xcodegen generate
open PassVault.xcodeproj
```

Select your signing team in Xcode and build for a real device. Swift Package Manager resolves the pinned libsodium wrapper. Enable a device passcode before creating a vault; enroll Face ID/Touch ID before enabling biometric unlock in app settings.

## Android

Requires JDK 17 and Android SDK 36. Open `android/` in Android Studio or use:

```sh
cd android
./gradlew :app:assembleDebug :app:testDebugUnitTest
```

Set `ANDROID_HOME` to your SDK, or create an untracked `android/local.properties` with `sdk.dir=...`. Minimum Android version is 11 (API 30). Test strong biometrics on a real device. Release signing is intentionally not configured with a shared development key. To make a signed Play Store bundle (AAB) and sideload APK locally, run `scripts/build-android-release.sh`; it creates your upload keystore on first use and keeps the key off GitHub. Output goes to `dist/`. To move existing installs to a new signing key without losing their data, run `scripts/rotate-signing-key.sh` once (it defaults to rotating from the Android debug key); after that `scripts/build-android-release.sh` attaches the rotation lineage to the sideload APK automatically. Back up both keystores and `~/.passvault-signing/lineage.bin`.

## Native security checks

The portable Swift core can be exercised without full Xcode:

```sh
swift run --package-path ios vault-security-checks
```

To validate a local migration file without copying credentials into the repo or printing them:

```sh
PASSVAULT_TEST_CSV=/Volumes/MacExternalDisk/pk_backup_2026-09-29.csv \
  swift run --package-path ios vault-security-checks
```

On a full Xcode installation, also run `swift test --package-path ios`. Build tools need Internet access to fetch dependencies; the shipped app does not.

## Migration

Password Keeper's CSV export drops extra usernames, passwords and other fields; its encrypted `.pkb2` export keeps everything. Prefer `.pkb2`: transfer it locally to the phone, unlock PassVault, open settings, choose Import, pick the file and enter the password you set when exporting. CSV import works the same way without a password. Review the record count and confirm. Verify records before removing the plaintext migration file. Do not commit real credentials: CSV and backup files are ignored by Git.

App passwords need at least 12 characters (encrypted backups can be attacked offline, so length matters) with uppercase and lowercase letters, a number and a symbol. On Android, export asks for the app password once (a counted attempt) and encrypts the backup with it. Encrypted backups and can be imported on either platform. There is no password reset service. Exported files remain independent of local erasure. The system file picker may offer third-party cloud providers, but the app itself implements no cloud integration.

## Validation in this workspace

The Swift core compiled, and 95 standalone security/migration checks passed, including the supplied CSV. iOS UI source passed Swift syntax parsing. Android CSV/schema unit tests are included but have not run. Full mobile builds, native UI type checking and biometric behavior have not yet been verified: this Mac initially had no full Xcode, Android SDK or JDK. XCTest was unavailable in its command-line-tools installation. These are release blockers, not evidence that the mobile apps have passed.
