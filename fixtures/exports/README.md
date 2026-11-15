# Export samples

`sample.1pux`: a 1Password unencrypted export in the documented 1PUX layout (a deflated zip with `export.attributes` and `export.data`),
written for PassVault's tests with Python's `zipfile`. It holds a login with a TOTP, extra fields and password history, a credit card,
a trashed note and an archived note. All values are test-only. Both apps' importer tests read it.

`skipped-attachment.1pux`: the same `export.data`, preceded by a dummy attachment declared as 32 MiB of zeros.
Its DEFLATE stream deliberately starts with a reserved block type. Both apps must import the records without trying to decompress
the unrelated attachment; otherwise this fixture fails immediately. No real user data is included.

`data-descriptor.1pux`: the same entries as `sample.1pux`, written by Python's `zipfile` to an unseekable stream, so every
entry has flag 8 and a signed data descriptor after its data instead of sizes in its local header. Both apps' ZIP reader
tests read it and change single bytes of it, and of `sample.1pux`, to check that the local header and descriptor must
agree with the central directory.
