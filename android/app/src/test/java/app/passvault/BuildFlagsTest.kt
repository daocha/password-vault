package app.passvault

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class BuildFlagsTest {
    @Test fun onlyTheEmulatorTestBuildRelaxesKeystoreRules() {
        // Debug (and release, which shares the defaults) keep hardware-backed keys that only work while the phone is unlocked.
        assertTrue(BuildConfig.REQUIRE_UNLOCKED_DEVICE); assertFalse(BuildConfig.ALLOW_SOFTWARE_KEYSTORE)
        val gradle = File("build.gradle.kts").readText()
        for (relaxed in listOf("\"REQUIRE_UNLOCKED_DEVICE\", \"false\"", "\"ALLOW_SOFTWARE_KEYSTORE\", \"true\"")) {
            assertEquals(relaxed, 1, Regex(Regex.escape(relaxed)).findAll(gradle).count())
            assertTrue("$relaxed only in qa", gradle.indexOf(relaxed) > gradle.indexOf("create(\"qa\")"))
        }
    }
}
