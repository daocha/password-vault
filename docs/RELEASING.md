# Releasing PassVault for Android

PassVault ships two Android builds of the same app, `app.passvault.mobile`:

| Build | Gradle variant | Updates through | Network |
|---|---|---|---|
| GitHub sideload APK | `release` | GitHub Releases, in the app | `INTERNET` and `REQUEST_INSTALL_PACKAGES`, for updates only |
| Google Play | `playRelease` | Google Play | none |

Both are signed with **one key**, and Play App Signing holds that same key, so a phone can move between the
GitHub and Play builds without uninstalling and keeps its vault.

## Toolchain

On the maintainer's Mac, use the portable toolchain from `AGENTS.md`; nothing is installed:

```bash
T=/private/tmp/aquarestore-tools
export JAVA_HOME=$(echo $T/jdk-17*/Contents/Home) ANDROID_HOME=$T/android-sdk GRADLE_USER_HOME=$T/gradle-home
```

The release scripts also need the GitHub CLI, logged in once with `gh auth login`.

## Signing key

| Setting | Default | Environment |
|---|---|---|
| Keystore | `~/.passvault-signing/passvault-upload.jks` | `PASSVAULT_KEYSTORE` |
| Alias | `upload` | `PASSVAULT_KEY_ALIAS` |
| Keystore password | asked for, hidden | `PASSVAULT_KEYSTORE_PASSWORD` |
| Key password | asked for (Enter = keystore password) | `PASSVAULT_KEY_PASSWORD` |
| Rotation lineage | `~/.passvault-signing/lineage.bin` | `PASSVAULT_LINEAGE` |

The name "upload" is historical: this is the app's only signing key, for GitHub and Play alike.

- If the key is on another computer, copy the `.jks` (and `lineage.bin`, if there is one) over directly, e.g.
  AirDrop or USB, never through email, chat or cloud sync. Keep it `chmod 600`, or point `PASSVAULT_KEYSTORE` at it.
- When no keystore is found, the scripts offer to create one. **Say no if you already have a key**: a new key
  cannot update existing installs.
- Back the keystore and its password up in two places, one offline. Losing it ends updates for GitHub installs.
- Passwords reach Gradle only through the environment of a single-use Gradle process; tests and lint run in
  a separate process that never sees them.
- `scripts/print-signing-fingerprint.sh [cert.pem]` prints the key's SHA-256 fingerprint (to compare with Play's
  **App integrity** page or to register the app for Android developer verification). It needs only a JDK or
  openssl, not the Android SDK, and never creates a key.

`scripts/rotate-signing-key.sh` makes the key the successor of an older one (by default the Android debug key) so
phones with builds signed by the old key update in place. The lineage is attached to the GitHub APK only.

## GitHub release

```bash
scripts/release-github.sh                     # asks for the version; add --play to build the Play bundle too
scripts/release-github.sh --version 2026.11.2 --play
```

1. Checks that tracked files are committed and nothing untracked sits in `android/` or `scripts/` (files elsewhere,
   such as release notes at the root, are fine), that `gh` is logged in, and that the tag is new.
2. A new version name raises `versionCode` by one (or use `--version-code`).
3. Builds and verifies the APK (`build-android-release.sh`): unit tests, release lint, signer, package, version,
   not debuggable. With `--play`, also builds the bundle (`build-android-play.sh`) from the same source.
4. Asks before publishing, then commits the version, tags `vX.Y.Z` and pushes branch and tag together: if the push is
   refused (e.g. protected `main`), nothing is pushed and the tag is removed. Merge the version commit through a
   pull request, then run again from the merged branch with the same `--version`.
5. Uploads the APK and SHA256SUMS to a draft release, then publishes it (`--draft` keeps it a draft).

`--dry-run` builds and verifies without any Git or GitHub writes. Other options: `--prerelease`, `--notes-file`,
`--skip-tests`. Outputs go to `dist/`.

## Google Play

```bash
scripts/build-android-play.sh                 # or release-github.sh --play, to match a GitHub release
```

It writes `dist/PassVault-<version>-<code>-play.aab` and `...-play-mapping.txt`, and checks that the bundle is signed
with the key and that the Play build requests neither `INTERNET` nor `REQUEST_INSTALL_PACKAGES`. It prints the key's
SHA-256 in the form Play Console shows.

### First upload (once)

1. Play Console: create the app (free, app), then complete **Policy → App content**: privacy policy URL, app access
   (no account; reviewers create their own vault), ads (none), content rating, target audience, data safety (no data
   collected or shared). After the first upload, also the foreground service declaration for the clipboard clearer
   (`specialUse`).
2. Store listing: descriptions, 512×512 icon, 1024×500 feature graphic, phone screenshots. Release builds block
   screenshots, so take them from the debug build with a test vault.
3. **Testing → Internal testing → Create new release.** At app signing choose **Change app signing key → Export and
   upload a key from Java keystore**. Download `pepk.jar` and the encryption key from that page and run:

   ```bash
   java -jar pepk.jar --keystore="$PASSVAULT_KEYSTORE" --alias=upload --output=encrypted_private_key.zip \
     --include-cert --rsa-aes-encryption --encryption-key-path=encryption_public_key.pem
   ```

   Upload the zip, then delete it and `pepk.jar`. Do not register a separate upload key: the same key signs the
   bundle. This choice is permanent; if Google generates the key instead, Play and GitHub installs can never
   update each other.
4. Upload the `.aab`, and the mapping file under **App bundle explorer → Downloads**. In **App integrity**, check
   that the app signing key's SHA-256 is the one `build-android-play.sh` printed.
5. Install from the internal test link on a phone that has the GitHub build: Play must offer **Update**.
6. Personal developer accounts need a closed test with at least 12 testers for 14 days before production access.

### Every later release

Run `scripts/release-github.sh --play`, then upload the bundle and its mapping file to Play. Both builds share one
`versionCode` sequence; Play rejects a code it has already seen.

## Keeping the scripts in sync with AquaRestore

`_signing-common.sh`, `build-android-debug.sh`, `build-android-release.sh`, `build-android-play.sh`,
`release-github.sh`, `rotate-signing-key.sh`, `print-signing-fingerprint.sh` and `tests/test_release_workflow.py`
are identical in PassVault and AquaRestore. Everything project-specific (app name, package, key defaults, build directories, forbidden Play
permissions, release notes, source checks) is in `scripts/release-settings.sh`. Change a shared file in both
repositories, and check with:

```bash
for f in _signing-common.sh build-android-debug.sh build-android-release.sh build-android-play.sh \
         release-github.sh rotate-signing-key.sh print-signing-fingerprint.sh tests/test_release_workflow.py; do
  diff -q ~/git/password-vault/scripts/$f ~/git/AquaRestore/scripts/$f
done
```

Test the scripts with `bash -n scripts/*.sh` and `python3 -m unittest discover -s scripts/tests -v`.
