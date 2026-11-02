# PassVault privacy policy

Last updated: 2 November 2026

This policy covers PassVault for Android and iOS, including the Google Play, App Store and GitHub Android releases.

PassVault is an offline password manager. It has no online account, developer-operated server, analytics, advertising or tracking, and does not sell personal data. Your vault contents are not sent to the developer.

## Data you store

Passwords, cards, notes, two-factor secrets and other vault records are stored encrypted on your device. The developer has no access to them and cannot recover your vault if you forget its master password. The app excludes its local vault storage from automatic device cloud backup and does not provide cloud synchronization.

Backups, exports and transfers happen only when you choose them. Encrypted backups and transfers protect their contents with encryption; CSV exports contain readable data and should be handled carefully. Files you save, copy or share outside the app are separate from its local vault storage. If you choose a cloud-backed file provider or another sharing app, that service may store or transmit the file under its own privacy policy. The vault's backup exclusion does not apply to those exported copies.

## Network and updates

- **Google Play Android version:** has no internet permission and does not connect to a network.
- **App Store iOS version:** the app itself does not contact a server. Apple handles App Store and TestFlight distribution and updates.
- **GitHub Android version:** connects to GitHub to check for updates and download an update when you choose. These requests contain no vault contents or app settings. GitHub receives ordinary connection information, including your IP address, and handles it under its own privacy policy.

Apple, Google and any file or sharing providers you choose operate independently of PassVault and have their own privacy policies.

## Camera, photos and files

Camera access is requested when you choose to scan a QR code for two-factor setup or vault transfer. Camera images are processed on your device and are not saved or uploaded by PassVault. You can also select a QR-code image through a system picker. Imports are read when you select them, and exports are written to the destination you choose.

Phone-to-phone transfers use encrypted QR codes or a transfer file you choose to share; PassVault does not send vault contents through a developer-operated server.

## Biometrics

Face ID, Touch ID and Android biometric authentication are handled by the operating system. PassVault receives an authentication result, not your face or fingerprint data.

## Clipboard

Copying a secret places it on the system clipboard so you can paste it elsewhere. You can disable secret copying, choose a clearing delay (including no timed clearing), and choose whether copied text is cleared when the vault locks.

- **Android:** copied secrets are marked sensitive. Clearing uses the app's clipboard service and is subject to operating-system restrictions.
- **iOS:** copied secrets are marked local-only so they are not shared through Universal Clipboard. A selected clearing delay is supplied as a clipboard expiration time.

Clipboard clearing cannot remove information already pasted into another app or captured elsewhere.

## Autofill

**Android only:** if you enable autofill, PassVault processes information from the requesting app or login form on your device to suggest matching records. It sends only the credentials you explicitly approve to that app or form. It does not send this information to the developer. The iOS version currently has no system AutoFill extension.

## Preferences and deletion

Nonsecret preferences, such as appearance, language, locking choices and backup-reminder metadata, are stored locally outside the encrypted vault. You can delete individual records in the app. Removing the app removes its local vault files; iOS Keychain items may persist until a fresh installation clears them. Separately saved exports, backups and transfer files remain wherever you saved or shared them; manage or delete those copies at their destinations.

## Children

PassVault is not directed at children. The app does not collect children's personal information or provide advertising or tracking.

## Changes and contact

Changes to this policy are published in this file with an updated date. For questions, open an issue at https://github.com/daocha/password-vault/issues. GitHub issues are public: never include passwords, vault files, recovery phrases, two-factor secrets or other sensitive information. Information you voluntarily include in a support request is visible to its recipients and is handled by the support platform under its own privacy policy.
