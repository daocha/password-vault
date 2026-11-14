# PassVault support

PassVault is an offline password manager for iPhone, iPad and Android. It has no account and no server:
your vault is encrypted and stays on your device. That also means **nobody, including the developer, can
see your vault or recover it for you.**

## Get help

- **Questions and bug reports:** [open an issue on GitHub](https://github.com/daocha/password-vault/issues).
  Issues are public. Never include passwords, vault or backup files, recovery phrases, two-factor
  secrets or screenshots that show them.
- **Security problems:** [report them privately](https://github.com/daocha/password-vault/security/advisories/new)
  instead of opening a public issue.

When reporting a bug, please include your device model, iOS or Android version, the PassVault version
(on iPhone: **Settings → General → iPhone Storage → PassVault**) and the steps that lead to the problem.

## Common questions

### I forgot my master password

It cannot be reset or recovered. PassVault never stores it, and there is no server to recover it from.
If you have an encrypted backup, you can start a new vault and import that backup with the password
you chose when you exported it.

### My vault says it was erased

After 10 wrong passwords in a row, PassVault erases the vault on that device to stop guessing. Tap
**Start a new vault**, create a new master password, then import your most recent backup from
**Settings → Import**.

### How do I back up my vault?

Unlock PassVault, open **Settings** and choose **Export encrypted backup**. Keep the file somewhere safe
and remember its password. A plaintext CSV export is also available, but anyone who gets that file can
read it, and it leaves out two-factor keys and seed phrases.

Deleting the app deletes the vault on that device, so export a backup first.

### How do I move to a new phone?

On the old phone, choose **Settings → Send to another phone** and follow the steps: the new phone can
scan the encrypted QR codes, or you can share a transfer file and type its transfer code. On the new
phone, choose **Receive from another phone**. Transfers between iPhone and Android work too. An
encrypted backup moved to the new phone and imported there works as well.

### How do I import from another password manager?

Export from the other app, copy the file to your phone, then choose **Settings → Import** and pick
the file. PassVault recognises BlackBerry Password Keeper backups (`.pkb2` and CSV), KeePass and
KeePassXC (`.kdbx` or XML), Bitwarden (unencrypted JSON or CSV), 1Password (`.1pux` or CSV), browser
password CSVs (Chrome, Edge, Firefox, Safari) and other CSV exports with name, URL, username and
password columns. After importing, check your records and delete the exported file, which is not
encrypted.

### Face ID or Touch ID is greyed out or does not work

Biometric unlock needs Face ID or Touch ID set up in iOS **Settings**, and PassVault must be allowed to
use it (**Settings → PassVault → Face ID**). Then unlock PassVault with your password and turn on
**Settings → Biometric unlock**. If you change your enrolled faces or fingerprints, unlock once with
your password and turn biometric unlock on again.

### Can PassVault fill passwords into other apps?

On iPhone and iPad, not yet: copy a password or code from PassVault and paste it. Copied secrets are not
shared to your other devices through Universal Clipboard, and you can choose when the clipboard is
cleared in Settings. The Android version supports autofill.

### Does PassVault sync to iCloud or back up to the cloud?

No. The vault is excluded from device and cloud backups and is never uploaded. Only files you export
yourself leave the app, and they go wherever you choose to save them.

## More information

- [Privacy policy](PRIVACY.md)
- [Security model](docs/SECURITY.md)
- [Features on iOS and Android](docs/FEATURES.md)
- [Source code](https://github.com/daocha/password-vault)
