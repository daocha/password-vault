# PassVault encrypted backup

Extension: `.pvault`. All data is binary; there are no text separators. New backups are version 2 (`QVAULT02`). Version 1 (`QVAULT01`) files made by earlier builds are still read.

## Version 2 (`QVAULT02`, written by current builds)

| Offset | Bytes | Meaning |
| --- | --- | --- |
| 0 | 8 | ASCII `QVAULT02` |
| 8 | 4 | Argon2id memory cost in KiB, unsigned big-endian (written: 262,144 = 256 MiB) |
| 12 | 4 | Argon2id passes (opslimit), unsigned big-endian (written: 4) |
| 16 | 16 | Cryptographically random Argon2id salt |
| 32 | 24 | Cryptographically random XChaCha20-Poly1305 nonce |
| 56 | variable | Ciphertext followed by 16-byte Poly1305 tag |

The first 32 bytes are authenticated additional data. Readers accept a memory cost of 64 MiB to 1 GiB and 3 to 10 passes and reject anything outside that range before doing any expensive work, so a malicious header can neither select weaker parameters nor an excessively expensive one. Because the header is authenticated and is also an input to the key, altering the cost fields yields a different key and the file fails to decrypt. They cannot be used to downgrade a file.

The backup password is the app password (Android) or a separate backup password (iOS). It is normalized to Unicode NFKC and then UTF-8 encoded, with no trimming or NUL terminator. Derive a 32-byte key using libsodium `crypto_pwhash` with `crypto_pwhash_ALG_ARGON2ID13` and the header's cost (one lane). Encrypt with `crypto_aead_xchacha20poly1305_ietf_encrypt`. A portable backup has no device secret and no attempt limit, so the cost per password guess is the only protection beyond the password itself; version 2 raises it from version 1's 64 MiB / 3 passes.

## Version 1 (`QVAULT01`, read only)

| Offset | Bytes | Meaning |
| --- | --- | --- |
| 0 | 8 | ASCII `QVAULT01` |
| 8 | 16 | Cryptographically random Argon2id salt |
| 24 | 24 | Cryptographically random XChaCha20-Poly1305 nonce |
| 48 | variable | Ciphertext followed by 16-byte Poly1305 tag |

The first 24 bytes are authenticated additional data. The cost is fixed at opslimit 3 and memlimit 67,108,864 bytes (64 MiB), one lane. Builds before normalization keyed these files from the password's UTF-8 bytes exactly as typed, so a reader tries the NFKC-normalized password first and, only if normalization changes the text, the as-typed bytes second. Version 1 files are never written.

## Newer versions

A file whose first eight bytes are `QVAULT` followed by two ASCII digits greater than `02` was made by a newer PassVault. Readers must report that as a newer-version file ("update the app") before asking for a password or trying any other format such as CSV, rather than as a wrong password or an unrecognised file. The same applies to local state saved by a newer version: Android state files that start with `PVS` and a digit above `2`, and iOS state whose `version` is above 1. Readers leave that state untouched so updating the app opens it. Earlier builds cannot do this, so they show their generic failure instead.

## Plaintext (both versions)

The plaintext is a UTF-8 JSON array. Each record has string properties `id`, `name`, `website`, `group`, `updatedAt`; boolean `favorite`; ordered `fields`; and a `legacy` object mapping strings to strings. An optional string `type` is absent or `login` for passwords and `seed` for a BIP-39 seed phrase record: its words are a `password` field labelled `Seed phrase` (single spaces, English wordlist, 12 or 24 words, valid checksum), with an optional `password` field `BIP-39 passphrase` and an optional `note`. `type` `totp` is an authenticator (RFC 6238 time-based one-time password) record: its key and settings are one `password` field labelled `Authenticator` whose value is an `otpauth://totp/` URI, with an optional `note`. Writers produce the canonical form `otpauth://totp/<issuer>:<account>?secret=<Base32, no padding>&issuer=<issuer>&algorithm=SHA1|SHA256|SHA512&digits=6|7|8&period=<1–300>` (the issuer prefix and parameter are omitted when empty; label and issuer are percent-encoded UTF-8 with `%20` for spaces); readers also accept the parameters in any order, lowercase Base32, padding and missing optional parameters (SHA1, 6 digits, 30 seconds). The record `name` is the display name. HOTP (counter-based) URIs are rejected. Readers that do not understand `type` must preserve it. Seed and authenticator records are never written to CSV. Each field has strings `id`, `kind`, `label`, `value`, `question`. `kind` is `username`, `password`, `note`, or `question`. A question's answer is `value`. IDs are unique within their respective collections. UI hides password and question values by default.

Readers accept at most 16 MiB plaintext, 10,000 records and 200 fields per record. Reject unknown magic, truncation, oversize input, invalid schemas and authentication failure before saving anything. Import appends with new record IDs after confirmation; it never replaces existing records implicitly.

The cipher suite is fixed by the version; only the Argon2id cost varies, within the bounds above. A future suite requires a new version. There is no embedded verifier separate from authenticated encryption, and no attempt counter in portable backups: copied files can always be attacked offline.

## Local storage

Local data uses a separate random 32-byte data key. Ciphertext is `nonce || ciphertext || tag`, with a fresh UUID filename authenticated as additional data. The protected state points to the committed file. Writers create ciphertext first, update the protected state pointer, then clean old ciphertext. Local password wrapping combines Argon2id output (64 MiB, 3 passes, NFKC-normalized password) with a random device secret using keyed BLAKE2b-256: key = device secret, message = UTF-8 `PassVault/device-wrap/v1` followed by the Argon2id key. The data-key wrapper authenticates UTF-8 `PassVault/key/v1`.

A vault or backup made before passwords were normalized was keyed from the text exactly as typed. For ASCII passwords the two forms are identical. Otherwise the as-typed form is accepted as a fallback within the same counted attempt, and a vault that opened that way is immediately re-wrapped in the normalized form with a fresh salt and device secret.

Changing the app password replaces the data key as well as the wrapping: a new data key encrypts the vault into a new file, the state is committed pointing at that file with the new wrapper, and the old file is removed. The biometric copy holds the old data key, so it is deleted first and biometric unlock must be enabled again afterwards.

iOS stores the state in device-only, passcode-protected Keychain, which an app-container file restore cannot roll back. Android keeps the state in a file under `noBackupFilesDir`, encrypted with AES-256-GCM under an Android Keystore key and authenticating UTF-8 `PassVault/state/v2` followed by the header. The file is `"PVS2" | u32be generation | iv 12 | ciphertext+tag`. Every state write that records a new attempt, a new vault file or a new password moves to a new Keystore key (alias `passvault-state-g<generation>`) and deletes all older ones after the file is committed, so a copied older state file has no key left to decrypt it and is refused as a missing key. Only the write that clears the counter after a proven password reuses the current key; it can never make an older copy more useful. Files from before generations (`iv | ciphertext`, fixed alias `passvault-state-v1`) are read once and migrated on the next write. Android erasure durably writes a nonsecret denial marker and deletes every state key, preventing reuse of previously copied state ciphertext. Interrupted cleanup resumes on next access. Biometric access protects a separate data-key copy with Keychain `biometryCurrentSet` or per-operation Android `BiometricPrompt.CryptoObject` + Keystore authentication. These device adapters intentionally differ; backups interoperate.

## CSV

### Password Keeper `.pkb2` import

Read-only import of BlackBerry Password Keeper encrypted exports (the format was read from the app's own exporter). Layout: `"PKB2"`, big-endian u32 version (1 or 2), 32-byte salt, 16-byte IV, u32 length + AES-256-CBC "keys" block + HMAC-SHA256, u32 length + AES-256-CBC records block + HMAC-SHA256. Version 2 derives 64 bytes with scrypt (N=65536, r=8, p=1) from the UTF-8 password (version 1: PBKDF2-HMAC-SHA256, 10000 iterations); the first 32 bytes are the AES key and the last 32 the HMAC key for the keys block, which holds the records' AES key, HMAC key and IV. Both MACs are verified before decryption. Records are JSON (`u` id, `t` type p/n/l/c, `fav`, `lm` modified time, `f` ordered fields with `n` label, `v` value, `t` type). Fields are imported in their original order: the first title and website become the entry name and website; usernames, passwords, notes and security questions keep their position; a password's history goes into that password field's own `history` list (`[{"value","changedAt"}]`, omitted when empty; shown newest first from the field's history icon) and is never mixed with fields the user names "Previous password". PassVault also records history itself: when a saved record's password or security answer differs from the stored value, the old value is added to that field's `history` with the change time (newest 10 kept per field; seed phrases are not tracked); extra titles and websites and custom fields become notes; list items become `[ ]`/`[x]` notes. Icons and trusted-app data are dropped. Unlike Password Keeper's CSV, a `.pkb2` file contains every field.

CSV: recognizes the supplied BlackBerry header, including `url,username,password,extra,name,grouping,fav,customFields,...`. Handles quoted commas, doubled quotes, CRLF, multiline notes and UTF-8 BOM. Original metadata is kept inside the encrypted record. Unrecognized legacy `customFields` strings are preserved as a hidden field; they are not guessed or dropped. The supplied migration sample contains no nonempty custom-field payloads, so other BlackBerry custom-field variants still require sanitized samples.

PassVault CSV adds `vaultFields`, a JSON encoding of ordered typed fields for lossless round trips between these apps. This extra column is not a claim that legacy BlackBerry versions can import every new field. CSV is plaintext; the app password authorizes export, but it cannot password-protect the resulting CSV. Do not open untrusted password CSVs in spreadsheet programs, which may evaluate formula-like cells. Exact values are preserved rather than silently prefixing and changing passwords.
