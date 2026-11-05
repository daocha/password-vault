"""A hacked build download must not reach the signing key or run unnoticed.
Run: python3 -m unittest discover -s scripts/tests -v
"""
from pathlib import Path
import re
import unittest

PROJECT = Path(__file__).resolve().parents[2]


class BuildSupplyChainTest(unittest.TestCase):
    def test_gradle_never_gets_signing_material(self):
        build = (PROJECT / "android/app/build.gradle.kts").read_text()
        # PassVault's ALLOW_SOFTWARE_KEYSTORE setting is about the app's own vault keys, so match the signing names only.
        for word in ("signingConfig", "_KEYSTORE_", "KEY_PASSWORD", "storePassword", "keyPassword"):
            self.assertNotIn(word, build)
        for script in ("build-android-release.sh", "build-android-play.sh", "_signing-common.sh"):
            text = (PROJECT / "scripts" / script).read_text()
            self.assertNotIn("run_signed_gradle", text)
            # Every Gradle run goes through the one function that removes the passwords first.
            for line in text.splitlines():
                if "./gradlew" in line:
                    self.assertEqual(script, "_signing-common.sh", line)
        common = (PROJECT / "scripts/_signing-common.sh").read_text()
        function = re.search(r"run_unsigned_gradle\(\) \(\n(.*?)\n\)", common, re.S).group(1)
        self.assertLess(function.index("unset"), function.index("./gradlew"))

    def test_gradle_distribution_is_pinned(self):
        wrapper = (PROJECT / "android/gradle/wrapper/gradle-wrapper.properties").read_text()
        self.assertRegex(wrapper, r"distributionSha256Sum=[0-9a-f]{64}")

    def test_libraries_are_verified_on_mac_and_linux(self):
        metadata = (PROJECT / "android/gradle/verification-metadata.xml").read_text()
        self.assertIn("<verify-metadata>true</verify-metadata>", metadata)
        versions = re.findall(r'name="aapt2" version="([^"]+)"', metadata)
        self.assertTrue(versions)
        for version in versions:
            self.assertIn(f"aapt2-{version}-osx.jar", metadata)
            self.assertIn(f"aapt2-{version}-linux.jar", metadata)

    def test_ci_does_not_install_tools_from_homebrew(self):
        for workflow in ("ios.yml", "test-builds.yml"):
            self.assertNotIn("brew install", (PROJECT / ".github/workflows" / workflow).read_text())


if __name__ == "__main__":
    unittest.main()
