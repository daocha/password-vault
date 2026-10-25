# KeePass test databases

Copied unchanged from [kdbxweb](https://github.com/keeweb/kdbxweb) (`resources/`, commit `7601e45d2a437f35a7fa3d767164eab60bc05d42`), MIT licensed
(see `LICENSE`). They were written by KeePass and KeePassXC, so PassVault's KDBX reader is tested against files it did not produce.
Both apps' tests read them from this folder.

| File | Format (from its header) | Password | Key file |
| --- | --- | --- | --- |
| `demo.kdbx` | KDBX 3.1, AES-KDF, AES-256, Salsa20 | `demo` | `demo.key` (XML v1) |
| `AesChaCha.kdbx` | KDBX 3.1, AES-KDF, ChaCha20 | `demo` | `demo.key` |
| `Argon2.kdbx`, `Argon2id.kdbx` | KDBX 4.0, Argon2d / Argon2id, AES-256 | `demo` | `demo.key` |
| `Argon2ChaCha.kdbx` | KDBX 4.0, Argon2d, ChaCha20 | `demo` | `demo.key` |
| `KDBX4.1.kdbx` | KDBX 4.1, AES-KDF, AES-256 | `test` | none |
| `AesKdfKdbx4.kdbx` | KDBX 3.1 despite its name, AES-KDF, AES-256 | `demo` | none |
| `cyrillic.kdbx` | KDBX 3.1, uncompressed | `пароль` | none |
| `Key32.kdbx`, `Key64.kdbx`, `KeyWithBom.kdbx` | KDBX 3.1 | `test` | 32-byte binary, 64-digit hex, XML with BOM |
| `KeyV2.kdbx`, `NoPassWithKeyFile.kdbx` | KDBX 3.1 | none | `KeyV2.keyx` (XML v2), `NoPassWithKeyFile.key` |
| `EmptyPass.kdbx` | KDBX 3.1 | empty | none |
| `binkey.kdbx` | KDBX 3.1 | `test` | `binkey.key` (hashed) |

`demo.xml` is the KeePass XML export of the demo database. In every `demo` database the group `General` (under the root group `sample`) holds "my entry"
(user `me`, password `mypass`, URL `http://me.me`, notes `some notes`, fields `my field` and protected `my field protected`, expiring
2015-08-29) with one history version whose password was `pass`; the `Recycle Bin` group holds deleted entries.
