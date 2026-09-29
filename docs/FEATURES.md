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
- Production-quality password-strength estimation; character count alone is not a strength meter.
- Decide whether OS autofill integrations are in the desired parity scope. Neither an iOS credential provider extension nor Android autofill service is included yet.
- Additional accessibility, large-vault performance, localization, and destructive-action UX review.
- Real iOS and Android compilation, UI testing, device lifecycle tests, biometric and hardware-backed-storage verification, cross-platform backup exchange, signing and independent security review.

See `SECURITY.md` for the offline anti-rollback and compromised-device limits. Do not claim that a local counter can survive arbitrary OS compromise or that all USB attacks are impossible.
