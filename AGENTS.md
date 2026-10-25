# Working in this repository

PassVault is an offline password vault for Android (`android/`) and iOS (`ios/`). The app holds secrets: keep
it offline. Only the GitHub sideload build (`src/release`) and a debug build given a LAN update server
(`src/lanUpdate`) may have the INTERNET permission, and only to update themselves.

`main` is protected: make every change on a branch and open a pull request.

## Building and testing

- Android: `./gradlew :app:testDebugUnitTest :app:assembleDebug :app:lintDebug` in `android/` (CI runs all three).
  Instrumented tests run on an emulator with the emulator-only `qa` variant: `:app:connectedQaAndroidTest`.
- iOS: `swift run vault-security-checks` in `ios/` (needs Xcode).

## Building the debug APK on the maintainer's Mac

Do not use `scripts/` to build it (`build-android-debug.sh`, `setup-release-env.sh` and the like use
Homebrew and install software). Install nothing: no Homebrew, no system JDK, no Android Studio, nothing
under `~/Library`. Run Gradle directly with a portable toolchain kept in one folder under `/tmp`, shared
with the maintainer's other Android projects:

```bash
T=/private/tmp/aquarestore-tools
export JAVA_HOME=$(echo $T/jdk-17*/Contents/Home) ANDROID_HOME=$T/android-sdk GRADLE_USER_HOME=$T/gradle-home
cd android && ./gradlew --console=plain :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
```

`/tmp` is cleared on reboot. If `$T` is missing, recreate it there and nowhere else:
- JDK 17: the Temurin tarball from
  `https://api.adoptium.net/v3/binary/latest/17/ga/mac/aarch64/jdk/hotspot/normal/eclipse`, extracted into `$T`.
- Android SDK: the macOS "command line tools only" zip from developer.android.com/studio, extracted to
  `$ANDROID_HOME/cmdline-tools/latest`, then
  `yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --sdk_root=$ANDROID_HOME --licenses` and
  `sdkmanager --sdk_root=$ANDROID_HOME 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0'`.
- Gradle: the wrapper downloads it into `$GRADLE_USER_HOME` by itself. A half-wiped Gradle cache fails with
  "Could not read workspace metadata": delete `$GRADLE_USER_HOME/caches` and build again.

Do not set `ANDROID_USER_HOME`: the APK must be signed with `~/.android/debug.keystore`, the key the
phone's installed debug build has. Check that the package is `app.passvault.mobile.debug`
(`$ANDROID_HOME/build-tools/36.0.0/aapt2 dump badging android/app/build/outputs/apk/debug/app-debug.apk`).
Spurious "Unresolved reference" errors for functions in the same package mean a stale build: run `clean`.

After a successful build, copy the APK to `android/dist/PassVault-debug.apk`. Then publish it to the phone over
the LAN: when the gitignored `.env` sets `PASSVAULT_DEV_UPDATE_HOST` (see `.env.example`), the build has already
written `android/dist/dev-update/`. Run `scripts/serve-dev-update.sh` in the background, since it keeps serving
until stopped. If a server is already running, leave it running: it serves the folder, so the new build is
picked up. Never write the address from `.env` into a committed file, commit message or pull request.

## Releases

Releases come from `scripts/release-github.sh`. Release signing comes only from the environment; never commit
a keystore, password or signing config.
