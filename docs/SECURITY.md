# Security model and release gates

PassVault is an offline native iOS/Android app. No server, analytics, account, cloud backup, or remote recovery. Build tools download dependencies; the shipped app does not need a network connection.

## Guarantees and limits

The vault must only persist authenticated ciphertext. A random data key is wrapped using a password-derived key and a device-bound secret. Biometrics release a separately protected copy of the data key through the OS, not a UI-only authentication flag. On Android a successful strong-biometric unlock resets the failed-password counter. Exports require the app password again, even after biometric unlock; that check is a counted attempt toward the 10-failure limit. On Android, encrypted backups are encrypted with that same app password (fresh Argon2id salt per file) and deliberately do not depend on the originating device, so an exported file is only as strong as the app password against offline guessing. Changing the app password does not re-encrypt earlier backups.

Physical possession or a USB cable must not expose plaintext through app file sharing, Android backup, logs, or unencrypted databases. This does not imply protection against every OS exploit: a compromised process or operating system can capture secrets while they are in use. StrongBox availability varies by Android device. Root/jailbreak detection cannot establish trust.

10 consecutive failed app-password attempts trigger cryptographic erasure. Reserve an attempt durably before checking the password, serialize all authentication, and fail closed on missing/corrupt state. A process termination during verification consumes an attempt. Keychain/Keystore protection raises the cost of tampering, but neither platform offers arbitrary offline apps a universal rollback-proof monotonic counter. Restoring a full compromised-device snapshot can defeat software counters. No offline portable backup can enforce an attempt limit against someone making copies. Do not advertise an unbypassable counter.

Erasure destroys the local decryption keys; flash wear leveling prevents a promise of physical overwrite. Independently exported files are not erased. CSV exports are plaintext and cannot require a password when another application opens them. Wrong encrypted-backup passwords reject that import; they do not erase the existing vault.

Swift/Kotlin strings, UI bindings, and managed arrays can leave transient copies in process memory. Clearing references and overwriting mutable buffers is best effort, not a guarantee of complete memory zeroization. Android clipboard clearing can be delayed or prevented if the OS stops the process; receiving apps can retain copied values. iOS cannot universally prevent screenshots of an active app. The privacy cover protects inactive scenes, not a compromised compositor.

Android window hardening: `FLAG_SECURE` (no screenshots or recents thumbnails), the whole UI is excluded from autofill services and content capture, other apps' overlays are hidden while the app is visible (API 31+), and touches are ignored while an untrusted window covers the app. Seed-phrase editors never write to the clipboard.

Debug builds are debuggable: with USB debugging enabled on an unlocked phone, `adb run-as` can act as the app (including using its Keystore keys) and a debugger can read its memory. Keep valuable data only in a signed release build.

While one of the app's own system pickers (import/export file chooser) is open, auto-lock uses a fixed 2-minute grace period instead of the chosen timeout, so leaving the app from inside a picker still locks the vault. App passwords must be at least 12 characters, because encrypted backups use the same password and can be attacked offline without an attempt limit. The data key is zeroed when the activity is destroyed.

With a 1- or 5-minute auto-lock, Android may freeze the app in the background and deliver the screen-off event late, so on return the vault can appear for a moment before locking. The elapsed-time check on return still enforces the timeout; choose "Immediately" to avoid this.

## Cryptography

Version 1 uses libsodium Argon2id v1.3 (64 MiB, 3 iterations, 1 lane, 32-byte key) and XChaCha20-Poly1305 (256-bit key, random 192-bit nonce, 128-bit authentication tag). Fixed, authenticated format metadata prevents algorithm confusion; input sizes are bounded before expensive work. There is no single “most secure” encryption algorithm: these are established choices, not a claim that newer means stronger.

Sources: [libsodium password hashing](https://doc.libsodium.org/password_hashing/default_phf), [XChaCha20-Poly1305](https://doc.libsodium.org/secret-key_cryptography/aead/chacha20-poly1305/xchacha20-poly1305_construction), [Apple Keychain](https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web), [Android Keystore](https://developer.android.com/privacy-and-security/keystore).

## Required before release

- Compile and run both apps on real devices, including biometric enrollment changes, cancellation, device restart, backgrounding, and process death.
- Verify no plaintext appears in files, backups, recent-app snapshots, crash reports, logs, or exported temporary files.
- Exercise all 10 attempts, concurrent unlock/export, interrupted state writes, deleted state, restored old ciphertext, reinstall, and key invalidation.
- Verify import/export interoperability, malformed files, authentication failures, CSV escaping, and legacy custom-field variants with sanitized fixtures.
- Benchmark Argon2id on the minimum supported devices; never silently lower cost.
- Audit dependencies, native binary provenance, accessibility, and distribution signing. Obtain an independent security review before storing valuable credentials or publishing security claims.
- Check Android native library 16 KiB page-size compatibility and final merged release manifest; no Internet permission or backup path should be introduced transitively.
