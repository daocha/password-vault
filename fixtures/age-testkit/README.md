# age test kit

Copied unchanged from [C2SP/CCTV](https://github.com/C2SP/CCTV) (`age/testdata`, commit `4448f2097b2daa812c91a26141f9f36c2096b9ca`),
available under 0BSD, CC0 1.0 or the Unlicense. Each file is a text header (`expect`, `payload` SHA-256, `identity`, …), an empty line,
then an age file, optionally zlib-compressed or ASCII-armored. They were written by the age authors' generator, so PassVault's age
reader (`android/app/src/main/java/app/passvault/Age.kt`) is tested against files it did not produce. PassVault does not open
passphrase-encrypted age files, so `passphrase` vectors are checked only never to decrypt, and to reject headers that mix scrypt with
other stanzas.

`../age-spec/hybrid-key.txt` is the post-quantum identity and its recipient from the age specification ([c2sp.org/age](https://c2sp.org/age)),
which checks how the long `age1pq1…` public key is derived and encoded.
