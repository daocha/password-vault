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

Before editing version metadata or building, `release-github.sh` checks that the output paths for the requested version and build number are unused. This also applies to dry runs. It checks the APK and checksums, the bundle and mapping with `--play`, and the archive and export directory with `--app-store`; publishing also checks the generated notes path unless `--notes-file` is supplied. Move conflicting outputs aside before retrying. Other versions and outputs for unselected platforms may remain in `dist/`. To retry only an Apple upload, use `build-ios-app-store.sh --upload-archive PATH` with the existing archive.

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

Test the scripts with `for script in scripts/*.sh; do bash -n "$script" || exit; done` and `python3 -m unittest discover -s scripts/tests -v`.

## iOS App Store / TestFlight

Use full Xcode 26+ with the iOS 26+ SDK, XcodeGen, Python 3, and a paid Apple Developer team.
Install these yourself; the App Store script installs nothing. In Xcode Settings > Accounts, sign in
and select the team. Set `DEVELOPMENT_TEAM` to the ten-character team ID. Alternatively set all three
of `ASC_KEY_PATH` (private `.p8` file outside the repository), `ASC_KEY_ID`, and `ASC_ISSUER_ID` for a
team App Store Connect API key with provisioning permissions.

For automatic setup, put `DEVELOPMENT_TEAM` and, when using an API key, all three `ASC_*`
settings in the repository-root `.env` (see `.env.example`). Existing `scripts/.env` files are
also supported. Both `release-github.sh --app-store` and `build-ios-app-store.sh` load these
four Apple settings and export them to child processes. Other `.env` keys are ignored by
this loader. Exported variables take priority over `scripts/.env`, which takes priority over
root `.env`. No `.env` file is required when the variables are already exported; Android-only
releases do not load Apple settings. Missing or invalid signing settings explain how to fix them.

Use one `KEY=value` assignment per line; optional `export`, single/double quotes, blank lines,
comments and Windows line endings are supported. Values are literal: no command substitution
or general variable expansion is performed. A leading `~`, `$HOME` or `${HOME}` in unquoted
or double-quoted values is expanded to the user's home directory. Keep `.env` and private
keys out of Git. The `.p8` key path must exist on the machine running the release.

```bash
# With Apple signing settings in .env or scripts/.env:
./scripts/build-ios-app-store.sh --check
./scripts/build-ios-app-store.sh
# Or build alongside the Android GitHub release (also add --play for the Play bundle):
./scripts/release-github.sh --version 2026.11.2 --app-store
```

The App Store build takes `versionName` and `versionCode` from `android/app/build.gradle.kts` and
passes them to Xcode as `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. App Store versions must
have three numeric components without a beta suffix. The current single-component build number
must be 1–9999, and every new uploaded build needs an unused, increasing number. To rebuild the same
version after an upload, increase the version code in a branch and merge that metadata through a PR.
Do not reuse an existing GitHub tag. `--skip-tests` skips the Swift package checks too.

Outputs are `dist/PassVault-VERSION-CODE.xcarchive` and
`dist/PassVault-VERSION-CODE-app-store/PassVault.ipa`. Keep the archive, including its dSYMs, for crash reports.
The build refuses to overwrite either output. Move failed/local artifacts aside before rebuilding.
The default checks run Swift package tests; run simulator and real-device app checks before submission.

`--app-store` builds the archive and IPA, then uploads the archive to App Store Connect after the GitHub release succeeds. It does not submit for review or add the IPA to GitHub.
`--dry-run --app-store` builds locally without uploading.
Export and signing may contact Apple to obtain provisioning assets even during a dry run.
For iOS-only builds or to retry a failed upload, upload the **existing** archive without rebuilding:

```bash
./scripts/build-ios-app-store.sh --upload-archive dist/PassVault-2026.11.2-CODE.xcarchive
```

Replace `CODE` with the build number printed by the build. Upload retries use the same archive;
if processing already succeeded in App Store Connect, do not upload it again. Archive bundle ID
and team are checked before export/upload. Xcode keeps the build number unchanged.

Before uploading, register the release bundle ID in Apple Developer and create its iOS app record
in App Store Connect. After processing, test with TestFlight, complete the listing, iPhone/iPad
screenshots, privacy policy and App Privacy answers, age rating, price/availability and encryption
questions, select the build and submit for App Review in App Store Connect. Uploading does not
submit for review or release the app. App Store updates are distributed by Apple, while the Android
GitHub APK retains its existing update flow.

PassVault declares non-exempt encryption and links libsodium. Complete Apple’s encryption questionnaire and obtain any required documentation before review; do not flip the declaration to bypass it.

### App Store upload validation failures

**Invalid Export Compliance Code:** In App Store Connect, open PassVault → App Information →
App Encryption Documentation. Complete the questionnaire and, if required, submit documentation
for Apple's review. Once Apple has approved the documentation and issued a code, create the
gitignored `ios/Config/AppStore.local.xcconfig` with the assigned value:

```xcconfig
INFOPLIST_KEY_ITSEncryptionExportComplianceCode = YOUR_APPLE_APPROVED_CODE
```

The Release configuration includes this local file when present; Debug builds do not.
Use the actual code for PassVault, not the document ID or an API key. An empty or incorrect
code cannot resolve the rejection. This configuration does not change the app's declaration
of non-exempt encryption.
See Apple's [encryption documentation workflow](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/)
and [compliance-code key](https://developer.apple.com/documentation/bundleresources/information-property-list/itsencryptionexportcompliancecode).

**Missing supported orientations:** The generated app Info.plist declares all four orientations
for iPhone and iPad, including the iPad-specific key, to support iPad multitasking.

Both fixes require rebuilding the archive: `--upload-archive` exports the existing signed app
and cannot insert missing metadata. Preserve the failed archive and export directory by moving
them aside before rebuilding with `scripts/build-ios-app-store.sh`. Keep version `2026.11.3`
if that is the App Store version you intend to upload. If Apple already accepted the build
number, increase `versionCode` through a PR first. Do not recreate the published GitHub tag
or rerun the combined GitHub release to repair an iOS-only upload.

After rebuilding, upload the new archive using `--upload-archive` as shown above. Confirm its
app Info.plist contains `ITSEncryptionExportComplianceCode` with the approved value and
`UISupportedInterfaceOrientations` / `UISupportedInterfaceOrientations~ipad` with all four
orientations before retrying.

References: [Apple SDK requirements](https://developer.apple.com/news/upcoming-requirements/?id=04282026a),
[create the app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/),
[upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/),
[submit for review](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/).

The shared files also include `build-ios-app-store.sh` and `tests/test_ios_app_store.py`;
keep these and `release-github.sh` / `tests/test_release_workflow.py` identical in both repositories.
The iOS scheme and test command belong in each project's `release-settings.sh`.

The Apple `.env` loader in `_signing-common.sh` and `tests/test_release_env.py` are shared too.
Keep that test identical alongside the existing shared release scripts and tests.
