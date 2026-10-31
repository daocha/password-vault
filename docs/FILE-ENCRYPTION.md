# File encryption

Status: Android. Not on iOS: no maintained age library exists for Swift, and building one is left for later (see "iOS" below).

## What it does

PassVault encrypts any file to a key kept in the vault. The encrypted file is written wherever the user chooses (Downloads, a USB
drive, cloud storage) and is never stored by PassVault. Only the key is in the vault, so it moves with what already moves the vault:
encrypted `.pvault` backups and phone-to-phone transfers. A vault backup stays small however many files are encrypted.

Files use [age v1](https://c2sp.org/age), an open format with a published specification and test vectors. Files PassVault encrypts open
with the official `age` command-line tool, and files encrypted there to the vault's public key open in PassVault (see "On a computer").

> **The computer needs age 1.3.0 or later.** Keys PassVault creates are post-quantum (`AGE-SECRET-KEY-PQ-1…`, public key `age1pq1…`),
> which age supports from 1.3.0; older versions do not recognise them. Classic keys imported from `age-keygen` (`AGE-SECRET-KEY-1…`)
> work with any age version.

## On a computer

With age 1.3.0 or later (`age --version`):

- **Open a PassVault file.** Reveal the key entry's secret in PassVault, save it as a file (here `key.txt`), and run
  `age -d -i key.txt -o report.pdf report.pdf.age`. The secret is then outside the vault's protection: delete `key.txt` afterwards.
- **Encrypt a file for the vault.** Copy or share the public key from the File encryption screen (`age1pq1…`; safe to share), and run
  `age -r age1pq1… -o report.pdf.age report.pdf`. Add `-a` for a text (ASCII-armored) file. PassVault opens it with the vault's key.

Both directions, both key types, armored files and the chunk boundaries are checked on every pull request against the official tools
(`AgeInteropTest`, below).

## Keys

- **Type.** New keys are age's post-quantum hybrid type: ML-KEM-768 combined with X25519 (X-Wing), wrapped with HPKE
  (`AGE-SECRET-KEY-PQ-1…`, public key `age1pq1…`, as made by `age-keygen -pq`). A file stays secret unless both ML-KEM-768 and X25519 are
  broken, so files kept for years are not exposed by a future quantum computer. Classic X25519 keys (`AGE-SECRET-KEY-1…`) made with
  `age-keygen` can be imported. An imported key is used for decryption, and for encryption only when it is the vault's first key.
- **Where it lives.** A key is an ordinary secure note: one password-kind field labelled `age secret key` holding the identity string,
  plus a notes field. Nothing in the vault format changes, so backups, transfers, iOS and older Android builds keep the entry as a note
  (iOS shows it as a note with a hidden field). Android recognises it by that label and a valid identity, hides its Edit button, gives
  it a key icon and warns before it is deleted.
- **Several keys.** Every key in the vault is tried when decrypting. New files are encrypted to the most recently added key only;
  age's rule is not to mix post-quantum and classic recipients in one file. "Added" is a `fileKeyCreated` timestamp in the record's
  hidden `legacy` metadata (kept by backups, transfers and iOS), not `updatedAt`: moving an old key into a group must not make it
  active again after the user rotated away from it. An entry without the stamp (from the first test build, or made by
  hand on iOS) is stamped from its `updatedAt` by `VaultEngine` as soon as it is loaded (in memory) or saved, before an edit can change that.
  A key created in the app is stamped after the newest existing key even if the clock is behind it (set back, or a restored key stamped
  in the future), so creating a key always makes it the active one.
- **Imported keys.** Importing a key is for opening files encrypted to it (old archives, say), so it must not silently become the key new
  files use. It is stamped one millisecond before the vault's oldest key, unless the vault has none, and the app says new files keep using
  the current key.
- **Public key.** Derived from the secret key when the screen opens; never stored. It can be copied (not marked sensitive, not
  auto-cleared: it is not a secret) or shared through Android's share sheet so a computer can encrypt for the vault.

## Strength

- The encrypted file alone cannot be brute-forced: it has no password. Opening it means recovering the 128-bit file key from the header,
  which needs the private key (or breaking both ML-KEM-768 and X25519).
- The private key is as safe as the vault. On the phone it is behind the app password, the device-bound secret and the 10-attempt erase.
  In a `.pvault` backup it is behind the app password with Argon2id at 256 MiB / 4 passes, the only place offline guessing is possible.
  Anyone holding a backup can guess at the app password on a computer, with no attempt limit, so its strength is what protects the files'
  keys there. Two things make this matter more for files than for logins: a leaked website password can be changed, but a file someone
  already has stays readable once its key is recovered; and changing the app password does not protect backups already saved, which
  keep the old one. New app passwords must therefore be hard to guess, not just mixed in character types (see `SECURITY.md`); the
  create-key and backup dialogs say so, and a backup made with an easily guessed older password warns.
- The payload is ChaCha20-Poly1305 in 64 KiB chunks (age's STREAM), so truncation, reordering and changes are detected.

What encryption does not hide: the file's size (roughly), and its name, which is kept with `.age` added (the save dialog lets the user
rename it, and the screen says so).

## Losing the key

Like any private key, losing it loses the files. PassVault reduces the chance:

- Creating a key requires ticking "I understand and will back up my vault".
- The File encryption screen shows a "Back up" banner while any key is not in the last encrypted backup. Saving a backup records
  a fingerprint of each key it holds (truncated SHA-256 of the 256-bit secret, in ordinary preferences, per vault), so a key whose
  secret was replaced elsewhere counts as new. Backups saved before fingerprints were recorded cannot establish key coverage, so the
  banner stays visible until a fresh encrypted backup is saved. Each export keeps its bytes, fingerprints, format and source vault
  together: another export or a vault lock cannot change which keys or vault a completed backup is recorded for.
- Deleting a key entry (alone or in a bulk delete) shows a specific warning.
- Changing the app password keeps the key: it is vault content, re-encrypted with the vault.

## Flows (Android)

Settings › Security › File encryption.

- **Encrypt.** Pick a file → choose where to save `name.age` → encrypt with progress (cancellable) → offer to delete the plaintext
  original (`DocumentsContract.deleteDocument`; if its provider refuses, the user is told to delete it there).
- **Decrypt.** Pick a file → its header is checked first, so "not an age file" or "not for any key in this vault" is reported before
  anything is saved → choose where to save (`name.age` → `name`; otherwise `name.decrypted`) → decrypt → reminder that the copy is not
  protected. ASCII-armored files (`age -a`) are decoded line by line as they are read, so their size is not limited by memory. A
  passphrase file (`age -p`) is reported as such, not as "not for any key in this vault".
- **Failure.** age authenticates each chunk, so a damaged file is found only where the damage is. Any failure or cancellation empties and
  deletes the output, so a partial plaintext is never left behind or mistaken for the whole file. Cancellation is checked on every
  write and again after the file is closed (a small file is read in full before anything is written), and once more
  on the main thread just before success is accepted (`FileCrypt.guarded`). Locking runs on the main thread too, so nothing can
  lock in between; a complete output that is never accepted, including when the coroutine is cancelled on its way back from the
  worker thread, is removed. If the output can be neither emptied nor deleted (its provider went away, say), the user is told its name
  and that it may hold decrypted data, instead of "nothing was saved".
- **Screen.** The progress dialog keeps the screen on: the screen turning off locks the vault, which would stop the job and delete its
  output.
- **Locking.** Locking the vault (screen off, auto-lock) or the activity being destroyed cancels a running job, with the same clean-up. While the system file picker is
  open the usual 2-minute picker grace period applies. If the vault locks while the save picker is open, the empty file the picker created is removed; an
  existing file picked to be replaced still has its content and is left alone.

## Implementation

- `Age.kt`: age v1 in Kotlin. The primitives come from BouncyCastle's lightweight API (already a dependency for KeePass import):
  X25519, ML-KEM-768, SHA3/SHAKE, HMAC-SHA-256, HKDF-SHA-256, ChaCha20-Poly1305. Age.kt itself composes them, and that code is
  security-critical: the HPKE key schedule (RFC 9180) and X-Wing combiner for mlkem768x25519, the chunk nonces and the
  last-chunk rules. The age test kit and the interop test against the official tools (see Tests) are what check this composition.
  Plaintext buffers and derived keys are wiped when done, including on failure; this is best effort, since the JVM may already have
  copied them. Streaming, 64 KiB chunks; header lines bounded to 16 KiB, header to 1 MiB,
  256 stanzas. Passphrase (scrypt) files cannot be opened, since PassVault only encrypts to the vault's own keys, but a header mixing an scrypt
  stanza with any other is rejected, as the spec requires. Hardware (tag) stanzas are ignored.
- `FileEncryption.kt`: the key entry, naming, the backup check, and streaming between document URIs.
- `FileEncryptionUi.kt`: the screen and progress dialog.

## Tests

- `AgeTest` (JVM) runs every vector of the age test kit (`fixtures/age-testkit`, from C2SP/CCTV) and checks the exact
  outcome (success with the payload's SHA-256, header / HMAC / payload / armor failure, no match), including the post-quantum vectors. Passphrase vectors must never decrypt, and the two that mix scrypt with other stanzas must
  be rejected as header failures.
  It also checks the spec's key encodings (`fixtures/age-spec`, including the 1,216-byte post-quantum public key), round trips at chunk
  boundaries, wrong keys, tampering and truncation, that plaintext buffers are wiped when writing fails part way, that a multi-megabyte
  armored file is decoded as it is read (checking its header reads about one buffer), and that passphrase files are reported as such.
- `FileKeysTest` (JVM): the key entry survives backup encoding, newest-added order (unchanged by later edits), imported keys not
  taking over encryption, stamping of older entries, the backup warning following the secret itself, file names.
- `FileJobTest` (JVM): each way a stop can meet the end of a job (after its last check, coroutine cancelled on the way back, failed
  removal, job failure) leaves no unaccepted output.
- `FileCryptInstrumentedTest` (emulator): the same code on Android's runtime through `ContentResolver`, and that failed or cancelled
  output is emptied, including a stop that lands after a small file was read in full.
- `AgeInteropTest` (JVM, in CI) runs against the official tools from filippo.io/age, pinned to v1.3.2 and installed with `go install`
  (Go checks the module against its checksum database). Files PassVault encrypts must open with `age -d`, for PassVault's own
  post-quantum key and a classic key from `age-keygen`; files `age` encrypts (binary and `-a`) must open in PassVault, for keys made by
  either; a file for several recipients opens with each; `age-keygen -y` derives the same public key as PassVault; `age` refuses a
  PassVault file for another key; and the tools must be 1.3.0 or later, as documented. Sizes cover empty, one byte and both sides of
  the 64 KiB chunk boundary. Locally the test skips itself unless `AGE_BIN_DIR` points at the tools; CI sets `AGE_INTEROP_REQUIRED`
  so it fails there instead of skipping.

## iOS

The key entry already travels to iOS as a secure note, and its secret key can be revealed there and used with any age tool, so files
are never stranded on Android. Encrypting on iOS needs an age implementation in Swift: CryptoKit has X25519, HKDF, HMAC,
ChaCha20-Poly1305 and (iOS 26) ML-KEM / X-Wing; SHA-3 and SHAKE would come from libsodium or a small implementation. The same test kit
would gate it.
