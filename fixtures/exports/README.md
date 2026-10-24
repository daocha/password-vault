# Export samples

`sample.1pux`: a 1Password unencrypted export in the documented 1PUX layout (a deflated zip with `export.attributes` and `export.data`),
written for PassVault's tests with Python's `zipfile`. It holds a login with a TOTP, extra fields and password history, a credit card,
a trashed note and an archived note. All values are test-only. Both apps' importer tests read it.
