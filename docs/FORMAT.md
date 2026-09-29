# PassVault encrypted backup v1

Extension: `.pvault`. All data is binary; there are no text separators.

| Offset | Bytes | Meaning |
| --- | --- | --- |
| 0 | 8 | ASCII `QVAULT01` |
| 8 | 16 | Cryptographically random Argon2id salt |
| 24 | 24 | Cryptographically random XChaCha20-Poly1305 nonce |
| 48 | variable | Ciphertext followed by 16-byte Poly1305 tag |

The first 24 bytes are authenticated additional data. Passwords are UTF-8 encoded without Unicode normalization, trimming, or a NUL terminator. Derive a 32-byte key using libsodium `crypto_pwhash` with `crypto_pwhash_ALG_ARGON2ID13`, opslimit 3 and memlimit 67,108,864 bytes (64 MiB). This profile uses one lane. Encrypt with `crypto_aead_xchacha20poly1305_ietf_encrypt`.

The plaintext is a UTF-8 JSON array. Each record has string properties `id`, `name`, `website`, `group`, `updatedAt`; boolean `favorite`; ordered `fields`; and a `legacy` object mapping strings to strings. An optional string `type` is absent or `login` for passwords and `seed` for a BIP-39 seed phrase record: its words are a `password` field labelled `Seed phrase` (single spaces, English wordlist, 12 or 24 words, valid checksum), with an optional `password` field `BIP-39 passphrase` and an optional `note`. Readers that do not understand `type` must preserve it. Seed records are never written to CSV. Each field has strings `id`, `kind`, `label`, `value`, `question`. `kind` is `username`, `password`, `note`, or `question`. A question's answer is `value`. IDs are unique within their respective collections. UI hides password and question values by default.

Readers accept at most 16 MiB plaintext, 10,000 records and 200 fields per record. Reject unknown magic, truncation, oversize input, invalid schemas and authentication failure before saving anything. Import appends with new record IDs after confirmation; it never replaces existing records implicitly.

The version fixes the KDF and cipher suite, so a malicious header cannot select weaker or excessively expensive parameters. A future profile requires a new version and explicit migration. There is no embedded verifier separate from authenticated encryption, and no attempt counter in portable backups: copied files can always be attacked offline.

## Local storage

Local data uses a separate random 32-byte data key. Ciphertext is `nonce || ciphertext || tag`, with a fresh UUID filename authenticated as additional data. The protected state points to the committed file. Writers create ciphertext first, update the protected state pointer, then clean old ciphertext. Local password wrapping combines Argon2id output with a random device secret using keyed BLAKE2b-256: key = device secret, message = UTF-8 `PassVault/device-wrap/v1` followed by the Argon2id key. The data-key wrapper authenticates UTF-8 `PassVault/key/v1`.

iOS stores this state in device-only, passcode-protected Keychain. Android wraps it with an Android Keystore AES-256-GCM key and authenticates UTF-8 `PassVault/state/v1`; the state file lives under `noBackupFilesDir`. Android erasure durably writes a nonsecret denial marker and deletes the state encryption key, preventing reuse of previously copied state ciphertext with that key. Interrupted cleanup resumes on next access. Biometric access protects a separate data-key copy with Keychain `biometryCurrentSet` or per-operation Android `BiometricPrompt.CryptoObject` + Keystore authentication. These device adapters intentionally differ; backups interoperate.

## CSV

### Password Keeper `.pkb2` import

Read-only import of BlackBerry Password Keeper encrypted exports (the format was read from the app's own exporter). Layout: `"PKB2"`, big-endian u32 version (1 or 2), 32-byte salt, 16-byte IV, u32 length + AES-256-CBC "keys" block + HMAC-SHA256, u32 length + AES-256-CBC records block + HMAC-SHA256. Version 2 derives 64 bytes with scrypt (N=65536, r=8, p=1) from the UTF-8 password (version 1: PBKDF2-HMAC-SHA256, 10000 iterations); the first 32 bytes are the AES key and the last 32 the HMAC key for the keys block, which holds the records' AES key, HMAC key and IV. Both MACs are verified before decryption. Records are JSON (`u` id, `t` type p/n/l/c, `fav`, `lm` modified time, `f` ordered fields with `n` label, `v` value, `t` type). Fields are imported in their original order: the first title and website become the entry name and website; usernames, passwords, notes and security questions keep their position; a password's history goes into that password field's own `history` list (`[{"value","changedAt"}]`, omitted when empty; shown newest first from the field's history icon) and is never mixed with fields the user names "Previous password". PassVault also records history itself: when a saved record's password or security answer differs from the stored value, the old value is added to that field's `history` with the change time (newest 10 kept per field; seed phrases are not tracked); extra titles and websites and custom fields become notes; list items become `[ ]`/`[x]` notes. Icons and trusted-app data are dropped. Unlike Password Keeper's CSV, a `.pkb2` file contains every field.

CSV: recognizes the supplied BlackBerry header, including `url,username,password,extra,name,grouping,fav,customFields,...`. Handles quoted commas, doubled quotes, CRLF, multiline notes and UTF-8 BOM. Original metadata is kept inside the encrypted record. Unrecognized legacy `customFields` strings are preserved as a hidden field; they are not guessed or dropped. The supplied migration sample contains no nonempty custom-field payloads, so other BlackBerry custom-field variants still require sanitized samples.

PassVault CSV adds `vaultFields`, a JSON encoding of ordered typed fields for lossless round trips between these apps. This extra column is not a claim that legacy BlackBerry versions can import every new field. CSV is plaintext; the app password authorizes export, but it cannot password-protect the resulting CSV. Do not open untrusted password CSVs in spreadsheet programs, which may evaluate formula-like cells. Exact values are preserved rather than silently prefixing and changing passwords.
