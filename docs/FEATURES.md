# Feature and validation status

This repository is a native implementation under development, not an audited or store-ready password manager.

| Capability | Implementation |
| --- | --- |
| Offline iOS / Android | SwiftUI and Jetpack Compose; no server or runtime network client |
| Master-password unlock | Argon2id + authenticated key wrapping + OS-protected device secret |
| Face ID / Touch ID / Android strong biometrics | Key release protected by the platform, requires real-device verification |
| CRUD, search, favorites, groups | Implemented in both native UIs |
| Hidden passwords and security answers | Eye-button reveal; reset when the editor closes or app locks |
| Strong generator | OS/libsodium randomness, rejection sampling, adjustable 12–128 characters and symbols |
| Ordered custom fields | Usernames, passwords, notes, question-answer pairs; drag reorder plus Android accessible move buttons |
| Clipboard | iOS local-only clipboard with 30-second expiration; Android sensitive clipboard with best-effort delayed clearing |
| Master-password change | Rewraps data key after checking the old password; old backups retain old passwords |
| Password Keeper .pkb2 import | Decrypts Password Keeper encrypted exports (scrypt + AES-CBC + HMAC) with the export password and imports all fields in their original order; password history is kept per password field and viewable (newest first) from a history icon; both platforms |
| Password history | Changing a saved password or security answer stores the old value with a timestamp in that field's history (newest 10); history is encrypted with the vault and included in backups; hand-made "Previous password" fields are unrelated |
| Authenticator (2FA codes) | RFC 6238 TOTP (SHA1/SHA256/SHA512, 6–8 digits, any period) generated offline. Add by scanning the site's QR code with the camera (Android: CameraX + ZXing; iOS: AVFoundation), reading it from a screenshot, or typing the setup key. Google Authenticator "Transfer accounts" export QR codes (`otpauth-migration://`) import all their TOTP accounts at once, skipping HOTP accounts and keys already in the vault. Keys are stored as `otpauth://` URIs inside the encrypted vault, so `.pvault` backups export and import them; they are never written to CSV |
| Cards and secure notes | Payment-card records (cardholder, number, expiry, security code, PIN; network detected from the number, shown as "Visa •••• 1234") and secure notes, listed with the passwords and filterable; never written to CSV |
| Expiry reminders | Optional reminder date on logins and notes; cards use their own expiry date. Records expiring within 30 days or already expired are badged in the list. Reminders are shown inside the app only: while locked, the app cannot read dates to post notifications |
| Vault health | On-device report (no network, stated on the screen): reused passwords, weak passwords, passwords unchanged for over a year (from password history, Password Keeper's set date, or the record's last change), expired or soon-expiring items, and well-known services with no 2FA code saved (advice only). Score 0–100. The same offline strength estimate on both platforms: a common-password list (also with leetspeak and digits or symbols around a word) and length × log2(character pool) with repeats, sequences and keyboard runs discounted. No breach lookup |
| Backup status and reminders | Settings shows when the last encrypted backup was saved (recorded only when the file is written; CSV does not count). A reminder (weekly, every 2 weeks, monthly by default, or off) appears in the vault list when no backup exists yet, or the last one is older than the interval and entries changed since; "Later" snoozes it for 3 days. Only times and the choice are kept, in ordinary app preferences |
| Imports from other managers | Recognised by content: KeePass `.kdbx` (KDBX 3.1 and 4.x; AES-KDF, Argon2d, Argon2id; AES-256 or ChaCha20; password, key file in every KeePass format, or both) and KeePass XML; Bitwarden JSON and CSV; 1Password `.1pux` and CSV; CSV from Chrome, Edge, Firefox, Safari, KeePass, KeePassXC, Dashlane, Proton Pass and others, matched by column names. Groups/folders, password history, expiry, custom fields (hidden when the source hides them), cards, notes and TOTP keys (as 2FA entries) are kept; attachments, icons and trash are not. Tested against real KeePass/KeePassXC databases (`fixtures/kdbxweb`) and the same sample exports on both platforms. Twofish and KDBX 1/2 are refused with advice |
| Decoy vault | Optional second app password, set up from the real vault, that opens a separate vault with its own data key and file. Unlocking always derives two keys, so its timing does not show whether a decoy exists. Decoy sign-ins never reset the failed-attempt count; 10 failures erase both vaults. Inside the decoy vault, the decoy and biometric settings are hidden and the real vault's password is not accepted. Biometrics always open the real vault |
| Phone-to-phone transfer | No network: the old phone (after its app password) shows a looping animated QR code of the vault, compressed and encrypted under a one-time 12-character code that is shown only on request and never in the QR codes; the new phone scans the frames in any order and asks for the code, then the usual import confirmation follows. The same payload can be saved as a `.pvtransfer` file (Quick Share, AirDrop, USB) and imported with the code. Works between Android and iOS (each app's tests open the other's transfer). Not counted as a backup |
| CSV migration | Supplied CSV tested; legacy metadata and unknown custom payloads preserved |
| Encrypted backup | Same documented Argon2id/XChaCha20-Poly1305 file format on both platforms |
| Export authorization | Requires current app password (a counted attempt) for every export, including CSV; Android encrypts backups with the app password |
| Import safety | Bounded parse, full authentication before import, append confirmation |
| 10 failures | Durable reservation before password checking; erasure tombstone precedes key/blob cleanup |
| Recovery after wipe | Explicitly create a new vault, then restore an independent export |
| Auto-lock | Android: immediately / 1 min / 5 min after leaving the app, or when the device locks; screen-off always locks |
| Capture protection | Android FLAG_SECURE; iOS inactive-scene privacy cover (iOS screenshots cannot be universally prevented) |
| Cloud backup | Excluded; no sync service |
| Launcher icon | Generated silver lock on navy, wired to iOS and Android resources |

## Still required before claiming full Password Keeper parity

- A version-specific BlackBerry feature checklist and migration samples containing its different custom-field encodings. Current sample exercises basic fields only.
- The vault health strength estimate is a deliberately simple offline heuristic (common list, character pool, pattern discounts), not a zxcvbn-grade model with dictionaries and names; the app-password rule still checks length and character classes only.
- Decide whether OS autofill integrations are in the desired parity scope. Neither an iOS credential provider extension nor Android autofill service is included yet.
- Additional accessibility, large-vault performance, localization, and destructive-action UX review.
- Real iOS and Android compilation, UI testing, device lifecycle tests, biometric and hardware-backed-storage verification, cross-platform backup exchange, signing and independent security review.

See `SECURITY.md` for the offline anti-rollback and compromised-device limits. Do not claim that a local counter can survive arbitrary OS compromise or that all USB attacks are impossible.
