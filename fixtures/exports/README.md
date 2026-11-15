# Export samples

`sample.1pux`: a 1Password unencrypted export in the documented 1PUX layout (a deflated zip with `export.attributes` and `export.data`),
written for PassVault's tests with Python's `zipfile`. It holds a login with a TOTP, extra fields and password history, a credit card,
a trashed note and an archived note. All values are test-only. Both apps' importer tests read it.

`skipped-attachment.1pux`: the same `export.data`, preceded by a dummy attachment declared as 32 MiB of zeros.
Its DEFLATE stream deliberately starts with a reserved block type. Both apps must import the records without trying to decompress
the unrelated attachment; otherwise this fixture fails immediately. No real user data is included.
