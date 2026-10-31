package app.passvault

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

/** Exercises the packaged suffix resource with Android's IDN implementation, as well as the JVM unit coverage. */
class AutofillSecurityInstrumentedTest {
    @Test fun bundledSuffixListKeepsTenantsSeparateOnAndroid() {
        for (suffix in listOf("github.io", "pages.dev", "appspot.com", "s3.amazonaws.com")) {
            assertEquals("victim.$suffix", AutofillMatch.baseDomain("login.victim.$suffix"))
            assertFalse(AutofillDomains.sameSite("victim.$suffix", "attacker.$suffix"))
        }
        assertNull(AutofillMatch.baseDomain("ward.kawasaki.jp"))
        assertEquals("city.kawasaki.jp", AutofillMatch.baseDomain("www.city.kawasaki.jp"))
        assertNotNull(AutofillMatch.baseDomain("example.ᬩᬮᬶ.id"))
    }

    @Test fun androidNormalizationRefusesDistinctAndAmbiguousOrigins() {
        assertTrue(AutofillDomains.sameSite("https://bücher.de/login", "xn--bcher-kva.de"))
        assertFalse(AutofillDomains.sameSite("faß.de", "fass.de"))
        assertFalse(AutofillDomains.sameSite("10.0.0.1", "192.168.0.1"))
        assertNull(AutofillDomains.host("https://bank.com@evil.com"))
        // In a browser, another tenant's frame or a malformed domain is never filled; Android's IDN refuses faß.de here too.
        val u = AutofillField.username; val p = AutofillField.password
        assertEquals(AutofillChoice(null, 1, "victim.github.io"), AutofillChoice.choose(listOf(u, p), listOf("attacker.github.io", "victim.github.io"), browser = true))
        assertNull(AutofillChoice.choose(listOf(u, p), listOf("faß.de", "faß.de"), browser = true))
        assertEquals(AutofillChoice(0, 1, null), AutofillChoice.choose(listOf(u, p), listOf(null, "faß.de"), browser = false))
    }

    @Test fun browserSignaturesAreReadThroughPackageVisibility() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        // Not on the browser list, or not installed: never verified.
        assertFalse(AutofillBrowsers.verify(context, context.packageName))
        assertFalse(AutofillBrowsers.verify(context, "org.mozilla.klar"))
        // Chrome ships on Google APIs images; when present, its real signature must verify (this needs the manifest's <queries>).
        val chrome = runCatching { context.packageManager.getPackageInfo("com.android.chrome", 0) }.isSuccess
        if (chrome) assertTrue(AutofillBrowsers.verify(context, "com.android.chrome"))
    }
}
